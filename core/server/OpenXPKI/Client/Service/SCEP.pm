package OpenXPKI::Client::Service::SCEP;
use Moose;

use Carp;
use English;
use Data::Dumper;
use Log::Log4perl qw(:easy);
use MIME::Base64;
use OpenXPKI::Exception;
use OpenXPKI::Client::Service::Response;

extends 'OpenXPKI::Client::Service::Base';

has transaction_id => (
    is => 'ro',
    isa => 'Str',
    lazy => 1,
    default => sub { return shift->attr()->{transaction_id}; }
);

has message_type => (
    is => 'ro',
    isa => 'Str',
    lazy => 1,
    default => sub {
        return shift->attr()->{message_type};
    }
);

has signer => (
    is => 'ro',
    isa => 'Str',
    lazy => 1,
    default => sub { return shift->attr()->{signer} || ''; }
);

# this can NOT be set via the constructor as we need other attributes
# to finally parse the message. The trigger "reads" attr which then
# triggers the actual parsing which allows us to keep attr read-only
has pkcs7message => (
    is => 'rw',
    isa => 'Str',
    init_arg => undef,
    trigger => sub { shift->attr() }
);

has attr => (
    is => 'ro',
    isa => 'HashRef',
    lazy => 1,
    builder => '__parse_message'
);


sub __parse_message {

    my $self = shift;

    my $pkcs7 = $self->pkcs7message();
    die "Message is not set or empty" unless($pkcs7);
    my $result = {};
    eval {
        $result = $self->backend()->run_command('scep_unwrap_message',{
            message => $pkcs7
        });
    };
    if ($EVAL_ERROR) {
        $self->logger->error("Unable to unwrap message ($EVAL_ERROR)");
        die  "Unable to unwrap message";
    }
    $self->logger->trace(Dumper $result);
    return $result;
}

sub _prepare_result {

    my $self = shift;
    my $workflow = shift;

    return OpenXPKI::Client::Service::Response->new({
        workflow => $workflow,
        result => $workflow->{context}->{cert_identifier},
    });

}

sub generate_pkcs7_response {

    my $self = shift;
    my $response = shift;

    my %params = (
        alias           => $self->attr()->{alias},
        transaction_id  => $self->transaction_id,
        request_nonce   => $self->attr()->{sender_nonce},
        digest_alg      => $self->attr()->{digest_alg},
        enc_alg         => $self->attr()->{enc_alg},
        key_alg         => $self->attr()->{key_alg},
    );

    if ($response->is_pending()) {
        $self->logger->info('Send pending response for ' . $self->transaction_id );
        return $self->backend()->run_command('scep_generate_pending_response', \%params);
    }

    if ($response->is_client_error()) {

        # if an invalid recipient token was given, the alias is unset
        # the API will take the  default token to generate the reponse
        # but we must remove the undef value from the parameters list
        delete $params{alias} unless ($params{alias});

        my $failInfo;
        if ($response->error == 40001) {
            $failInfo = 'badMessageCheck';
        } elsif ($response->error == 40005) {
            $failInfo = 'badCertId';
        } else {
            $failInfo = 'badRequest';
        }

        $self->logger->warn('Client error / malformed request ' . $failInfo);
        return $self->backend()->run_command('scep_generate_failure_response',
            { %params, failinfo => $failInfo });
    }

    if (!$response->is_server_error()) {
        my $conf = $self->config()->config();
        $params{chain} = $conf->{output}->{chain} || 'chain';
        return $self->backend()->run_command('scep_generate_cert_response',
        { %params, (
            identifier  => $response->result,
            signer      => $self->signer,
        )});
    }
    return;

}

around 'build_params' => sub {

    my $orig = shift;
    my $self = shift;
    my @args = @_;

    my $params = $self->$orig(@args);

    return unless($params); # something is wrong

    # nothing special if we are NOT in PKIOperation mode
    return $params unless ($self->operation() eq 'PKIOperation');

    $self->logger->debug('Adding extra params for message type ' . $self->message_type());

    if ($self->message_type() eq 'PKCSReq') {
        # This triggers the build of attr which triggers the unwrap call
        # against the server API and populates the class attributes
        $params->{pkcs10} = $self->attr()->{pkcs10};
        $params->{transaction_id} = $self->transaction_id();
        $params->{signer_cert} = $self->signer();

        # Load url paramters if defined by config
        my $conf = $self->config()->config()->{'PKIOperation'};
        if ($conf->{param}) {
            my $cgi = $args[0];
            my $extra;
            my @extra_params;
            # The legacy version - map anything
            if ($conf->{param} eq '*') {
                @extra_params = $cgi->url_param();
            } else {
                @extra_params = split /\s*,\s*/, $conf->{param};
            }
            foreach my $param (@extra_params) {
                next if ($param eq "operation");
                next if ($param eq "message");
                $extra->{$param} = $cgi->url_param($param);
            }
            $params->{_url_params} = $extra;
        }
    } elsif ($self->message_type() eq 'GetCertInitial') {
        $params->{pkcs10} = '';
        $params->{transaction_id} = $self->transaction_id();
        $params->{signer_cert} = $self->signer();
    } elsif ($self->message_type() =~ m{\AGet(Cert|CRL)\z}) {
        $params->{issuer} = $self->attr()->{issuer_serial}->{issuer};
        $params->{serial} = $self->attr()->{issuer_serial}->{serial};
    }

    $self->logger->trace(Dumper $params);

    return $params;
};

__PACKAGE__->meta->make_immutable;

__END__;
