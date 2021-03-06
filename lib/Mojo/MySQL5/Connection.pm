package Mojo::MySQL5::Connection;
use Mojo::Base 'Mojo::EventEmitter';

use utf8;
use Encode qw(_utf8_off _utf8_on);
use Digest::SHA qw(sha1);
use Scalar::Util 'weaken';
use Mojo::IOLoop;
use Mojo::MySQL5::URL;

has state => 'disconnected';

has url => sub { Mojo::MySQL5::URL->new('mysql:///') };

use constant DEBUG => $ENV{MOJO_MYSQL_DEBUG} // 0;

use constant {
  CLIENT_CAPABILITY => [ qw(
    LONG_PASSWORD FOUND_ROWS LONG_FLAG CONNECT_WITH_DB
    NO_SCHEMA COMPRESS ODBC LOCAL_FILES
    IGNORE_SPACE PROTOCOL_41 INTERACTIVE SSL
    IGNORE_SIGPIPE TRANSACTIONS RESERVED SECURE_CONNECTION
    MULTI_STATEMENTS MULTI_RESULTS PS_MULTI_RESULTS PLUGIN_AUTH
    CONNECT_ATTRS PLUGIN_AUTH_LENENC_CLIENT_DATA CAN_HANDLE_EXPIRED_PASSWORDS SESSION_TRACK
    DEPRECATE_EOF) ],

  SERVER_STATUS => [ qw(
    STATUS_IN_TRANS STATUS_AUTOCOMMIT RESERVED MORE_RESULTS_EXISTS
    STATUS_NO_GOOD_INDEX_USED STATUS_NO_INDEX_USED STATUS_CURSOR_EXISTS STATUS_LAST_ROW_SENT
    STATUS_DB_DROPPED STATUS_NO_BACKSLASH_ESCAPES STATUS_METADATA_CHANGED QUERY_WAS_SLOW
    PS_OUT_PARAMS STATUS_IN_TRANS_READONLY SESSION_STATE_CHANGED) ],

  FIELD_FLAG => [ qw(
    NOT_NULL PRI_KEY UNIQUE_KEY MULTIPLE_KEY
    BLOB UNSIGNED ZEROFILL BINARY
    ENUM AUTO_INCREMENT TIMESTAMP SET) ],

  CHARSET => {
    UTF8 => 33, BINARY => 63, ASCII => 65 },

  DATATYPE => {
    DECIMAL => 0x00, TINY => 0x01, SHORT => 0x02, LONG => 0x03,
    FLOAT => 0x04, DOUBLE => 0x05,
    NULL => 0x06, TIMESTAMP => 0x07,
    LONGLONG => 0x08, INT24 => 0x09,
    DATE => 0x0a, TIME => 0x0b, DATETIME => 0x0c, YEAR => 0x0d, NEWDATE => 0x0e,
    VARCHAR => 0x0f, BIT => 0x10,
    NEWDECIMAL => 0xf6, ENUM => 0xf7, SET => 0xf8,
    TINY_BLOB => 0xf9, MEDIUM_BLOB => 0xfa, LONG_BLOB => 0xfb, BLOB => 0xfc,
    VAR_STRING => 0xfd, STRING => 0xfe, GEOMETRY => 0xff },
};

use constant {
  REV_CHARSET => { reverse %{CHARSET()} },
  REV_DATATYPE => { map { chr(DATATYPE->{$_}) => $_ } keys %{DATATYPE()} },
};

# state machine
# doing => { state => '_op', state => '_op' }
use constant SEQ => {
  connect => {
    connected => '_recv_handshake',
    handshake => '_send_auth',
    auth => '_recv_ok',
  },
  query => {
    idle => '_send_query',
    query => '_recv_query_responce',
    field => '_recv_field',
    result => '_recv_row',
  },
  ping => {
    idle => '_send_ping',
    ping => '_recv_ok',
  },
  disconnect => {
    idle => '_send_quit',
    quit => '_recv_ok'
  }
};


# encode fixed length integer
sub _encode_int($$) {
  my ($int, $len) = @_;
  return substr pack('V', $int), 0, $len if $len >= 1 and $len <= 4;
  return substr pack('VV', int $int % 2 ** 32, int $int / 2 ** 32), 0, $len if $len == 6 or $len = 8;
  return undef;
}

# encode length coded integer
sub _encode_lcint($) {
  my $int = shift;
  return
    !defined $int ? pack 'C', 251 :
    $int <= 250 ? pack 'C', $int :
    $int <= 0xffff ? pack 'Cv', 252, $int :
    $int <= 0xffffff ? substr pack('CV', 253, $int), 0, 4 :
    pack 'CVV', 254, int $int % 2 ** 32, int $int / 2 ** 32;
}

# encode length coded string
sub _encode_lcstr($) {
  my $str = shift;
  return defined $str ? _encode_lcint(length $str) . $str : _encode_lcint($str);
}

# get fixed length integer
sub _get_int {
  my ($self, $len, $chew) = @_;
  my $data = $chew ? substr $self->{incoming}, 0, $len, '' : substr $self->{incoming}, 0, $len;
  return unpack 'C', $data if $len == 1;
  return unpack 'V', $data . "\0\0" if $len >= 2 and $len <= 4;
  return undef unless $len == 8;
  my $lo = unpack ('V', substr $data, 0, 4);
  my $hi = unpack('V', substr $data, 4, 4);
  return $hi ?
    int $lo + int $hi * 2 ** 32 : $lo;
}

sub _chew_int { shift->_get_int(shift, 1) }

# get length coded integer
sub _chew_lcint {
  my $self = shift;
  my $first = $self->_chew_int(1);
  return
    $first < 251 ? $first :
    $first == 251 ? undef :
    $first == 252 ? $self->_chew_int(2) :
    $first == 253 ? $self->_chew_int(3) :
    $first == 254 ? $self->_chew_int(8) : undef;
}

# get length coded string
sub _chew_lcstr {
  my $self = shift;
  my $len = $self->_chew_lcint;
  return defined $len ? substr $self->{incoming}, 0, $len, '' : undef;
}

# get zero ending string
sub _chew_zstr {
  my $self = shift;
  my $str = unpack 'Z*', $self->{incoming};
  return undef unless defined $str;
  substr $self->{incoming}, 0, length($str) + 1, '';
  return $str;
}

# get fixed length string
sub _chew_str {
  my ($self, $len) = @_;
  die "_chew_str($len) error" if $len > length $self->{incoming};
  return substr $self->{incoming}, 0, $len, '';
}


sub _send_auth {
  my $self = shift;

  my ($username, $password, $database, $crypt) =
    ($self->url->username, $self->url->password, $self->url->database, '');

  my @flags = qw(LONG_PASSWORD LONG_FLAG PROTOCOL_41 TRANSACTIONS SECURE_CONNECTION MULTI_RESULTS);
  push @flags, 'CONNECT_WITH_DB' if $database;
  push @flags, 'MULTI_STATEMENTS' if $self->url->options->{multi_statements};
  push @flags, 'FOUND_ROWS' if $self->url->options->{found_rows};
  my $flags = _flag_set(CLIENT_CAPABILITY, @flags);

  warn '>>> AUTH ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n",
    ' user:', $username, ' database:', $database,
    ' flags:', _flag_list(CLIENT_CAPABILITY, $flags),
    '(', sprintf('%08X', $flags), ')', "\n" if DEBUG > 1;

  _utf8_off $username; _utf8_off $password; _utf8_off $database;

  if ($password) {
    my $crypt1 = sha1($password);
    my $crypt2 = sha1($self->{auth_plugin_data} . sha1 $crypt1);
    $crypt = $crypt1 ^ $crypt2;
  }

  $self->state('auth');
  delete $self->{auth_plugin_data};
  return pack 'VVCx23Z*a*Z*',
    $flags, 131072, ($self->url->options->{utf8} // 1) ? CHARSET->{UTF8} : CHARSET->{BINARY},
    $username, _encode_lcstr($crypt), $database, 'mysql_native_password';
}

sub _send_quit {
  my $self = shift;
  warn '>>> QUIT ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n" if DEBUG > 1;
  $self->state('quit');
  return pack 'C', 1;
}

sub _send_query {
  my $self = shift;
  my $sql = $self->{sql};
  warn '>>> QUERY ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n",
    " sql:$sql\n" if DEBUG > 1;
  _utf8_off $sql;
  $self->state('query');
  return pack('C', 3) . $sql;
}

sub _send_ping {
  my $self = shift;
  warn '>>> PING ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n" if DEBUG > 1;
  $self->state('ping');
  return pack 'C', 14;
}

sub _recv_error {
  my $self = shift;
  my $first = $self->_chew_int(1);
  die "_recv_error() wrong packet $first" unless $first == 255;

  $self->{error_code} = $self->_chew_int(2);
  $self->_chew_str(1);
  $self->{sql_state} = $self->_chew_str(5);
  $self->{error_message} = $self->_chew_zstr;

  warn '<<< ERROR ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n",
    ' error:', $self->{error_code},
    ' state:', $self->{sql_state},
    ' message:', $self->{error_message}, "\n" if DEBUG > 1;

  $self->state('idle');
  $self->emit(error => $self->{error_message});
}

sub _recv_ok {
  my $self = shift;
  my $first = $self->_get_int(1);
  return $self->_recv_error if $first == 255;
  die "_recv_ok() wrong packet $first" unless $first == 0;

  $self->_chew_int(1);
  $self->{affected_rows} = $self->_chew_lcint;
  $self->{last_insert_id} = $self->_chew_lcint;
  $self->{status_flags} = $self->_chew_int(2);
  $self->{warnings_count} = $self->_chew_int(2);
  $self->{field_count} = 0;

  warn '<<< OK ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n",
    ' affected:', $self->{affected_rows},
    ' last_insert_id:', $self->{last_insert_id},
    ' status:', _flag_list(SERVER_STATUS, $self->{status_flags}),
    '(', sprintf('%04X', $self->{status_flags}), ')',
    ' warnings:', $self->{warnings_count}, "\n" if DEBUG > 1;

  $self->emit('connect') if $self->state eq 'auth';
  $self->emit('end') if $self->state eq 'query';
  $self->state('idle');
}

sub _recv_query_responce {
  my $self = shift;
  my $first = $self->_get_int(1);
  return $self->_recv_error if $first == 255;
  return $self->_recv_ok if $first == 0;

  $self->{field_count} = $self->_chew_lcint;

  warn '<<< QUERY_RESPONSE ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n",
    ' fields:', $self->{field_count}, "\n" if DEBUG > 1;

  $self->state('field');
}

sub _recv_eof {
  my $self = shift;
  my $first = $self->_get_int(1);
  return $self->_recv_error if $first == 255;
  die "_recv_eof() wrong packet $first" unless $first == 254;

  $self->_chew_int(1);
  $self->{warnings_count} = $self->_chew_int(2);
  $self->{status_flags} = $self->_chew_int(2);

  warn '<<< EOF ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n",
    ' warnings:', $self->{warnings_count},
    ' status:', _flag_list(SERVER_STATUS, $self->{status_flags}),
    '(', sprintf('%04X', $self->{status_flags}), ')', "\n" if DEBUG > 1;

  if ($self->state eq 'field') {
    $self->emit(fields => $self->{column_info});
    $self->state('result');
  }
  elsif ($self->state eq 'result') {
    $self->{column_info} = [];
    if ($self->{status_flags} & 0x0008) {
      # MORE_RESULTS
      $self->state('query');
    }
    else {
      $self->emit(end => undef);
      $self->state('idle');
    }
  }
}

sub _recv_field {
  my $self = shift;
  my $first = $self->_get_int(1);
  return $self->_recv_error if $first == 255;
  return $self->_recv_eof if $first == 254;
  die "_recv_field() wrong packet $first" if $first > 250;

  my $field = {};
  $field->{catalog} = $self->_chew_lcstr;
  $field->{schema} = $self->_chew_lcstr;
  $field->{table} = $self->_chew_lcstr;
  $field->{org_table} = $self->_chew_lcstr;
  $field->{name} = $self->_chew_lcstr;
  $field->{org_name} = $self->_chew_lcstr;
  $self->_chew_lcint;
  $field->{character_set} = $self->_chew_int(2);
  $field->{column_length} = $self->_chew_int(4);
  $field->{column_type} = $self->_chew_int(1);
  $field->{flags} = $self->_chew_int(2);
  $field->{decimals} = $self->_chew_int(1);
  $self->_chew_str(2);

  do { _utf8_on $field->{$_} for qw(catalog schema table org_table name org_name) }
    if ($self->url->options->{utf8} // 1);

  push @{$self->{column_info}}, $field;

  warn '<<< FIELD ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n",
    ' name:', $field->{name},
    ' type:', REV_DATATYPE->{chr $field->{column_type}}, '(', $field->{column_type}, ')',
    ' length:', $field->{column_length},
    ' charset:', REV_CHARSET->{$field->{character_set}} // 'UNKNOWN', '(', $field->{character_set}, ')',
    ' flags:', _flag_list(FIELD_FLAG, $field->{flags}), '(', $field->{flags}, ')', , "\n" if DEBUG > 1;
}

sub _recv_row {
  my $self = shift;
  my $first = $self->_get_int(1);
  return $self->_recv_error if $first == 255;
  return $self->_recv_eof if $first == 254;

  my @row;
  for (0 .. $self->{field_count} - 1) {
    $row[$_] = $self->_chew_lcstr;
    _utf8_on $row[$_]
      if $self->{column_info}->[$_]->{character_set} == CHARSET->{UTF8};
  }

  warn '<<< ROW ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n",
    join(', ', map { defined $_ ? "'" . $_ . "'" : 'null' } @row), "\n" if DEBUG > 1;

  $self->emit(result => \@row);
}

sub _recv_handshake {
  my $self = shift;
  my $first = $self->_get_int(1);
  return $self->_recv_error if $first == 255;

  $self->{protocol_version} = $self->_chew_int(1);
  $self->{server_version} = $self->_chew_zstr;
  $self->{connection_id} = $self->_chew_int(4);
  $self->{auth_plugin_data} = $self->_chew_str(8);
  $self->_chew_str(1);
  $self->{capability_flags} = $self->_chew_int(2);
  $self->{character_set} = $self->_chew_int(1);
  $self->{status_flags} = $self->_chew_int(2);
  $self->{capability_flags} |= $self->_chew_int(2) << 16;
  my $auth_len = $self->_chew_int(1);
  $self->_chew_str(10);
  $self->{auth_plugin_data} .= $self->_chew_str(12);
  $self->_chew_str(1);
  my $auth_plugin_name = $self->_chew_zstr;

  warn '<<< HANDSHAKE ', $self->{connection_id}, ' #', $self->{seq}, ' state:', $self->state, "\n",
    ' protocol:', $self->{protocol_version},
    ' version:', $self->{server_version},
    ' connection:', $self->{connection_id},
    ' status:', _flag_list(SERVER_STATUS, $self->{status_flags}),
    '(', sprintf('%04X', $self->{status_flags}), ')',
    ' capabilities:', _flag_list(CLIENT_CAPABILITY, $self->{capability_flags}),
    '(', sprintf('%08X', $self->{capability_flags}), ')',
    ' auth:', $auth_plugin_name, "\n" if DEBUG > 1;

  die '_recv_handshake() invalid protocol version ' . $self->{protocol_version}
    unless $self->{protocol_version} == 10;
  die '_recv_handshake() unsupported auth method ' . $auth_plugin_name
    unless $auth_plugin_name eq 'mysql_native_password';
  die '_recv_handshake() invalid auth data '
    unless $auth_len == 21 and length($self->{auth_plugin_data}) == 20;

  $self->state('handshake');
}

sub _reset {
  my $self = shift;

  undef $self->{$_} for qw(error_code sql_state error_message
      affected_rows last_insert_id status_flags warnings_count field_count);

  $self->{column_info} = [];
  $self->{seq} = 0;
  $self->{incoming} = '';
}

sub _ioloop {
  $_[1] ? Mojo::IOLoop->singleton : ($_[0]->{ioloop} ||= Mojo::IOLoop->new);
}

sub _seq_next_ready {
  my $self = shift;
  return 0 if length $self->{incoming} < 4;
  return length($self->{incoming}) - 4 >= $self->_get_int(3);
}

sub _seq_next {
  my ($self, $cmd, $writeonly) = @_;
  my $next = SEQ->{$cmd}{$self->state};
  warn 'stream state:', $self->state, ' doing:', $cmd, ' next:', ($next // ''), "\n" if DEBUG > 2;
  return unless $next;
  if (substr($next, 0, 6) eq '_send_') {
    my $packet = $self->$next();
    $self->{stream}->write(_encode_int(length $packet, 3) . _encode_int($self->{seq}, 1) . $packet);
  }
  elsif (substr($next, 0, 6) eq '_recv_') {
    return if $writeonly;
    my ($len, $seq) = ($self->_chew_int(3), $self->_chew_int(1));
    die "_next_packet() packet out of order $seq " . $self->{seq}
      if $self->{seq} and $seq != (($self->{seq} + 1) & 0xff);
    die "_next_packet() not ready" if $len > length($self->{incoming});
    $self->{seq}++;
    $self->$next();
  }
  else {
    $self->$next();
  }
}

sub _seq {
  my ($self, $cmd, $cb) = @_;

  $self->{stream} = Mojo::IOLoop::Stream->new($self->{socket});
  $self->{stream}->reactor($self->_ioloop(0)->reactor) unless $cb;
  $self->{stream}->timeout($self->url->options->{query_timeout})
    if $self->url->options->{query_timeout};
  weaken $self;

  $self->{stream}->on(read => sub {
    my ($stream, $bytes) = @_;
    $self->{incoming} .= $bytes;

    $self->_seq_next($cmd, 0) while $self->_seq_next_ready;

    if ($self->state eq 'idle') {
      $stream->steal_handle;
      delete $self->{stream};
      $cb ? $self->$cb() : $self->_ioloop(0)->stop;
    }
    else {
      $self->_seq_next($cmd, 1);
    }
  });
  $self->{stream}->on(error => sub {
    my ($stream, $err) = @_;
    warn "stream error: $err state:", $self->state, "\n" if DEBUG;
    $self->{error_message} //= $err;
    $self->emit(error => $err);
  });
  $self->{stream}->on(timeout => sub {
    warn "stream timeout state:", $self->state, "\n" if DEBUG;
    $self->{error_message} //= 'timeout';
  });
  $self->{stream}->on(close => sub {
    warn 'stream closed state:', $self->state, "\n" if DEBUG;
    $self->{socket} = undef;
    $self->state('disconnected');
    $self->{error_message} //= 'disconnected' unless $cmd eq 'disconnect';
    $cb ? $self->$cb() : $self->_ioloop(0)->stop;
  });

  $self->{stream}->start;
  $self->_seq_next($cmd, 1);
}

sub _cmd {
  my ($self, $cmd, $cb) = @_;
  die 'invalid cmd:' . $cmd unless exists SEQ->{$cmd};
  die 'invalid state:' . $self->state . ' doing:'. $cmd unless exists SEQ->{$cmd}{$self->state};

  $self->_reset;
  $self->_seq($cmd, $cb);
  $self->_ioloop(0)->start unless $cb;
  return $self->state eq 'idle' ? 1 : 0;
}

sub connect {
  my ($self, $cb) = @_;

  $self->state('connecting');
  $self->_reset;

  if ($self->url->host eq '' or $self->url->host eq 'localhost') {
    if (!$self->url->options->{socket}) {
      $self->url->options->{socket} = `mysql_config --socket`;
      chomp $self->url->options->{socket};
    }
    warn "Connecting to UNIX socket '", $self->url->options->{socket}, "'\n" if DEBUG;
    $self->{socket} = IO::Socket::UNIX->new(
      Peer => $self->url->options->{socket},
      Timeout => $self->url->options->{connect_timeout} // 10,
      Blocking => 0
    );
    return unless $self->{socket};
    $self->state('connected');
    $self->_seq('connect', $cb);
  }
  else {
    $self->{client} = Mojo::IOLoop::Client->new;
    $self->{client}->reactor($self->_ioloop(0)->reactor) unless $cb;
    weaken $self;

    $self->{client}->on(connect => sub {
      my ($client, $handle) = @_;
      delete $self->{client};
      $self->{socket} = $handle;
      $self->state('connected');
      $self->_seq('connect', $cb);
    });
    $self->{client}->on(error => sub {
      my ($client, $err) = @_;
      delete $self->{client};
      $self->state('disconnected');
      $self->emit(error => $err);
      $cb ? $self->$cb() : $self->_ioloop(0)->stop;
    });

    $self->{client}->connect(
      address => $self->url->host || '127.0.0.1',
      port => $self->url->port || 3306,
      timeout => $self->url->options->{connect_timeout} // 10
    );
  }

  $self->_ioloop(0)->start unless $cb;
}

sub disconnect { shift->_cmd('disconnect') }

sub ping {
  my ($self, $cb) = @_;
  return $self->state eq 'disconnected' ? 0 : $self->_cmd('ping', $cb);
}

sub query {
  my ($self, $sql, $cb) = @_;
  $self->{sql} = $sql;
  $self->_cmd('query', $cb);
}

sub DESTROY {
  my $self = shift;
  $self->disconnect if $self->state eq 'idle' and $self->{socket};
}

# Private util functions
sub _flag_list($$;$) {
  my ($list, $data, $sep) = @_;
  my $i = 0;
  return join $sep || '|', grep { $data & 1 << $i++ } @$list;
}

sub _flag_set($;@) {
  my ($list, @ops) = @_;
  my ($i, $flags) = (0, 0);
  foreach my $flag (@$list) {
    do { $flags |= 1 << $i if $_ eq $flag } for @ops; 
    $i++;
  }
  return $flags;
}

sub _flag_is($$$) {
  my ($list, $data, $flag) = @_;
  my $i = 0;
  foreach (@$list) {
    return $data & 1 << $i if $flag eq $_;
    $i++;
  }
  return undef;
}

1;

=encoding utf8

=head1 NAME

Mojo::MySQL5::Connection - TCP connection to MySQL Server

=head1 SYNOPSIS

  use Mojo::MySQL5::Conection;

  my $c = Mojo::MySQL5::Conection->new(
    url => Mojo::MySQL5->new(
      'mysql://test:password@127.0.0.1:3306/test?found_rows=1&connect_timeout=2')
  );

  Mojo::IOLoop->delay(
    sub {
      my $delay = shift;
      $c->connect($delay->begin);
    },
    sub {
      my ($delay, $c) = @_;
      $c->query('select * from test_data', $delay->begin);
    },
    sub {
      my ($delay, $c) = @_;
    }
  )->wait;


=head1 DESCRIPTION

L<Mojo::MySQL5::Conection> is Asyncronous Protocol Implementation for connection to MySQL Server 
managed by L<Mojo::IOLoop>.

=head1 EVENTS

L<Mojo::MySQL5> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head2 fields

  $c->on(fields => sub {
    my ($c, $fields) = @_;
    ...
  });

Emitted after posting query and fields definition is received.

=head2 result

  $c->on(result => sub {
    my ($c, $result) = @_;
    ...
  });

Emited when a result row is received.

=head2 end

  $c->on(end => sub {
    my $c = shift;
    ...
  });

Emited when query ended successfully.

=head2 error

  $c->on(error => sub {
    my ($c, $error) = @_;
    ...
  });

Emited when Error is received.


=head1 ATTRIBUTES

L<Mojo::MySQL5::Conection> implements the following attributes.

=head2 state

  my $state = $c->state;
  $c->state('disconnected');

Connection State.

Possible States are:

=over 2

=item disconnected

Initial state before connecting to server.

Same state after fatal erorr.

=item connected

Connection to server is established.

Waiting for C<Initial Handshake> packet.

=item handshake

Server responded with C<Initial Handshake>.

Next send C<Handshake Response> (authentication) packet.

=item auth

C<Handshake Response> (authentication) packet sent to server.

Next wait for C<OK> or C<Error> packet.

=item idle

Connection is idle and ready for sending commands.

=item query

C<COM_QUERY> packet sent to server.

Waiting for C<COM_QUERY Response> packet. C<OK> is expected for non-SELECT queries.

=item field

Waiting for C<Column Definition> packets. C<EOF> is expected for end of column definition.

=item result

Waiting for C<Text Resultset Row> packets. C<EOF> is expected for end of result rows.

=item ping

C<COM_PING> packet is sent to server.

Waitint for C<OK> packet.

=back

=head2 url

  my $url = $c->url;
  $c->url(Mojo::MySQL5::URL->new('mysql://localhost/test');

MySQL Connection URL.

Supported Options are:

=over 2

=item found_rows

Enables or disables the flag C<CLIENT_FOUND_ROWS> while connecting to the MySQL server.
Without C<found_rows>, if you perform a query like
 
  UPDATE $table SET id = 1 WHERE id = 1;
 
then the MySQL engine will return 0, because no rows have changed.
With C<found_rows>, it will return the number of rows that have an id 1.

=item multi_statements

Enables or disables the flag C<CLIENT_MULTI_STATEMENTS> while connecting to the server.
If enabled multiple statements separated by semicolon (;) can be send with single
call to L<query>.

=item utf8

If enabled default character set is to C<utf8_general_ci> while connecting to the server.
If disabled C<binary> is the default character set.

=item connect_timeout

The connect request to the server will timeout if it has not been successful
after the given number of seconds.

=item query_timeout

If enabled, the read or write operation to the server will timeout
if it has not been successful after the given number of seconds.

=item socket

Unix socket that is used for connecting to the server.

Determined by calling C<mysql_config --socket> unless specified.

Unix socket is used if host part of L</"url"> is C<''> or C<'localhost'>.
Use C<'127.0.0.1'> to connect to local machine via TCP.

=back

=head1 METHODS

L<Mojo::MySQL5::Conection> inherits all methods from L<Mojo::EventEmitter> and
implements the following new ones.

=head2 connect

  # Blocking
  $c->connect;
  # Non-Blocking
  $c->connect(sub { ... });

Connect and authenticate to MySQL Server.

=head2 disconnect

  $c->disconnect;

Disconnect gracefully from server.

=head2 ping
  
  say "ok" if $c->ping;

Check if connection is alive.

=head2 query

  # Blocking
  $c->query('select 1 as `one`');
  # Non-Blocking
  $c->query('select 1 as `one`', sub { ... });

Send SQL query to server.
Results are handled by events.

=head1 DEBUGGING

Debugging is enabled if environment variable MOJO_MYSQL_DEBUG is set.

Packet tracing is enabled if MOJO_MYSQL_DEBUG is 2 or greater.

=head1 AUTHOR

Svetoslav Naydenov, C<harryl@cpan.org>.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015, Svetoslav Naydenov.

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<http://dev.mysql.com/doc/internals/en/client-server-protocol.html>,

L<Mojo::MySQL5>.

=cut
