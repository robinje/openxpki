package OpenXPKI::Password;

use strict;
use warnings;
use utf8;

use OpenXPKI::Debug;
use OpenXPKI::Exception;
use OpenXPKI::Random;
use OpenXPKI::Server::Context qw( CTX );
use MIME::Base64;
use Digest::SHA;
use Digest::MD5;
use Proc::SafeExec;
use MIME::Base64;
use Crypt::Argon2;
use POSIX;

sub hash {

    ##! 1: 'start'

    my $scheme = shift;
    my $passwd = shift;

    my $params = shift;

    my $prefix = sprintf '{%s}', $scheme;

    my $computed_secret;

    if (my ($salted, $algo, $len) = $scheme =~ m{\A(s?)(md5|sha(224|256|384|512)?)\z}) {
        ##! 32: "$algo ($salted)"
        ##! 64: "$passwd / $params"

        my $ctx;
        if ($algo eq 'md5') {
            $ctx = Digest::MD5->new();
            $len = 128;
        } elsif ($algo eq 'sha') {
            $ctx = Digest::SHA->new();
            $len = 160;
        } else {
            $ctx = Digest::SHA->new($algo);
        }

        $ctx->add($passwd);

        my $salt = '';
        if ($params) {
            $salt = substr(decode_base64($params), ($len/8));
        } elsif ($salted) {
            # a salt with half the size of the hash function should be ok
            $salt = __create_salt($len / 16);
        }

        if ($salt) {
            $ctx->add($salt);
            $computed_secret = encode_base64( $ctx->digest() . $salt, '');
        } else {
            $computed_secret = $ctx->b64digest();
        }

    } elsif ($scheme eq 'crypt') {

        my $salt = $params ? $params : __create_salt(3);
        $computed_secret = crypt($passwd, $salt);

    } elsif ($scheme eq 'argon2') {

        ##! 64: $params
        my $salt;
        if ($params->{salt}) {
            $salt = $params->{salt};
        } elsif ($params->{saltbytes}) {
            $salt = __create_salt( int($params->{saltbytes}) )
        } else {
            $salt = __create_salt();
        }

        # argon2id_pass($passwd, $salt, $t_cost, $m_factor, $parallelism, $tag_size)
        $computed_secret = Crypt::Argon2::argon2id_pass( $passwd, $salt,
            ($params->{time} || 3),
            ($params->{memory} || '32M'),
            ($params->{p} || 1),
            ($params->{tag} || 16)
        );
        $prefix = '';

    } elsif ($scheme eq 'plain') {
        $computed_secret = $passwd;
    }

    if (!$computed_secret){
        ##! 4: 'unable to hash password'
        return undef;
    }
    return $prefix . $computed_secret;
}

sub check {

    my $passwd = shift;
    my $hash = shift;
    ##! 16:  $hash
    ##! 64: "Given password is $passwd"

    my $encrypted;
    my $scheme;

    if ($hash =~ m{ \{ (\w+) \} (.*) }xms) {
        # handle common case: RFC2307 password syntax
        $scheme = lc($1);
        $encrypted = $2;
    } elsif ( rindex($hash, "\$argon2id", 0) ==0 ){
        # handle special case of argon2
        return Crypt::Argon2::argon2id_verify($hash,$passwd);
    } elsif ($hash =~ m{\$[156]\$}) {
        # native format of openssl passwd, same as {crypt}
        $scheme = 'crypt';
        $encrypted = $hash;
        # prepend the old scheme to not break the equality check at the end
        $hash = "{crypt}$hash";
    } else {
        # digest is not recognized
        OpenXPKI::Exception->throw ( message => "Given digest is without scheme" );
    }

    ##! 16: $scheme
    OpenXPKI::Exception->throw (
        message => "Given scheme is not supported",
        params  => { SCHEME => $scheme }
    ) unless (OpenXPKI::Password::has_scheme($scheme));

    my $computed_hash = hash($scheme,$passwd,$encrypted);

    if (! defined $computed_hash) {
        OpenXPKI::Exception->throw (
            message => "Unable to check password against hash",
            params  => {
              SCHEME => $scheme,
            },
        );
    }

    ##! 32: "$computed_hash ?= $hash"
    $computed_hash =~ s{ =+ \z }{}xms;
    $hash       =~ s{ =+ \z }{}xms;
    return $computed_hash eq $hash;

}

sub has_scheme {
    my $scheme = shift;
    return ($scheme =~ m{\A(plain|crypt|argon2|s?md5|s?sha(224|256|384|512)?)\z});
}

sub __create_salt {

    my $bytes = shift || 16;
    return OpenXPKI::Random->new()->get_random($bytes);

}
1;

__END__;

=head1 Name

OpenXPKI::Password - password hashing and checking

=head1 Description

Provides utility functions for hashing passwords and checking passwords against a hash

=head1 Functions

=head2 hash I<scheme>, I<passwd>, I<params>

hashes a password according to the provided scheme.

SCHEME is one of sha (SHA1), md5 (MD5), crypt (Unix crypt), smd5 (salted
MD5), ssha (salted SHA1), ssha (salted SHA256) or argon2.

It returns a hash in the format C<{SCHEME}encrypted_string>, or undef if
no hash could be computed.

For argon2 the return format is unencoded token generated by Crypt::Argon2
C<$argon...>.

For all algorithms except argon2, I<params> can be the encoded part of a
prior call to hash which effectively extracts the salt from the given
string which will result in the same encoded string if the same password
was given. The default is to create a random salt of suitable size.

For argon2 I<params> must be a hashref with the following options,
options are passed as-is to Crypt::Argon2::argon2id_pass, details on
the options can be found there.

=over

=item salt

A literal value to be used as salt. The class does not make any checks so
make sure the salt has enough entropy.

=item saltbytes

Number of bytes to generate a salt, the default is 16 bytes. Is overridden
by salt.

=item time

argon2 time cost factor, default is 3.

=item memory

argon2 memory cost factor, expects a memory size in k, M or G, default is 32M.

=item p

paralellism factor, default is 1.

=item tag

tag size, default is 16.

=back

=head2 check

checks if a password matches the provided digest.

The digest must have the format: C<{SCHEME}encrypted_string> or must start with C<$argon2>

SCHEME is one of sha (SHA1), md5 (MD5), crypt (Unix crypt), smd5 (encrypted
MD5) or ssha (encrypted SHA1).

It returns 1 if the password matches the digest, 0 otherwise.


