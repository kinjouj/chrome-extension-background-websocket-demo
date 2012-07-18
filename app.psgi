use strict;
use warnings;
use utf8;
use AnyEvent::Handle;
use Plack::Builder;
use Protocol::WebSocket::Frame;
use Protocol::WebSocket::Handshake::Server;

my %channel;
my @message;

builder {
    mount '/websocket' => sub {
        my $env = shift;
        my $fh = $env->{'psgix.io'} or return [500, [], []];

        my $hs = Protocol::WebSocket::Handshake::Server->new_from_psgi($env);
        $hs->parse($fh) or return [500, [], [$hs->error]];

        my $code = sub {
            my ($handle, $message) = @_;

            if (defined $handle and ref($handle) eq 'AnyEvent::Handle' and defined $message) {
                my $frame = Protocol::WebSocket::Frame->new(type => 'text', buffer => $message);

                $handle->push_write($frame->to_bytes());
            }
        };

        return sub {
            my $respond = shift;
            my $frame = Protocol::WebSocket::Frame->new(version => $hs->version);
            my $h = AnyEvent::Handle->new(fh => $fh);

            $channel{fileno($fh)} = $h;

            $h->push_write($hs->to_string);

            $code->($h, $_) for @message;

            $h->on_read(sub {
                $frame->append($_[0]->rbuf);

                while (my $msg = $frame->next) {
                    push @message, $msg;

                    for (values %channel) {
                        $code->($_, $msg);
                    }
                }
            });

            $h->on_error(sub {
                warn "[ERROR]: @_";

                delete $channel{fileno($fh)};

                $h->destroy;

                undef $h;
            });
            $h->on_eof(sub {
                delete $channel{fileno($fh)};

                $h->destroy;

                undef $h;
            });
        }
    };
};
