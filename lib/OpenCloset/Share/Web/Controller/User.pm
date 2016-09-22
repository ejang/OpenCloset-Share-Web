package OpenCloset::Share::Web::Controller::User;
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use Mojo::URL;
use String::Random ();

has schema => sub { shift->app->schema };

=head1 METHODS

=head2 auth

    under /

=cut

sub auth {
    my $self = shift;

    my $user_id = $self->session('access_token');
    unless ($user_id) {
        my $login = Mojo::URL->new( $self->config->{opencloset}{login} );
        $login->query( return => $self->req->url->to_abs );
        $self->redirect_to($login);
        return;
    }

    my $user = $self->schema->resultset('User')->find( { id => $user_id } );
    my $user_info = $user->user_info;
    $self->stash( user => $user, user_info => $user_info );
    return 1;
}

=head2 logout

    # logout
    GET /logout

=cut

sub logout {
    my $self = shift;

    delete $self->session->{access_token};
    $self->redirect_to('welcome');
}

=head2 add

    GET /users/new

=cut

sub add {
    my $self = shift;
}

=head2 create

    POST /users

=cut

sub create {
    my $self = shift;

    my $v = $self->validation;
    $v->required('name');
    $v->required('email')->email;
    $v->required('password');
    $v->required('re-password');
    $v->required('gender')->in(qw/male female/);
    $v->required('birth')->like(qr/^\d{4}$/);
    $v->required('address1');
    $v->required('address2');
    $v->required('address3');
    $v->required('address4');

    if ( $v->has_error ) {
        my $failed = $v->failed;
        my $error  = '입력값이 유효하지 않습니다: ' . join( ', ', @$failed );
        my $input  = $v->input;
        $self->flash( input => $input, error => $error );
        return $self->redirect_to('/users/new');
    }

    my $name     = $v->param('name');
    my $email    = $v->param('email');
    my $password = $v->param('password');
    my $retype   = $v->param('re-password');
    my $birth    = $v->param('birth');
    my $address1 = $v->param('address1');
    my $address2 = $v->param('address2');
    my $address3 = $v->param('address3');
    my $address4 = $v->param('address4');

    my $user = $self->schema->resultset('User')->find( { email => $email } );
    if ($user) {
        my $error = "이미 사용중인 email 입니다: $email";
        my $input = $v->input;
        $self->flash( input => $input, error => $error );
        return $self->redirect_to('/users/new');
    }

    if ( $password ne $retype ) {
        my $error = "비밀번호를 다르게 입력하셨습니다.";
        my $input = $v->input;
        $self->flash( input => $input, error => $error );
        return $self->redirect_to('/users/new');
    }

    my $guard = $self->schema->txn_scope_guard;
    my $now   = DateTime->now;
    $user = $self->schema->resultset('User')->create(
        {
            name     => $name,
            email    => $email,
            password => $password,
            expires  => $now->epoch + ( 86400 * 30 * 12 ), # 1년 유효?
        }
    );

    $user->create_related(
        'user_info',
        {
            address1 => $address1,
            address2 => $address2,
            address3 => $address3,
            address4 => $address4,
            birth    => $birth,
        }
    );
    $guard->commit;

    $self->session( access_token => $user->id );
    $self->redirect_to('/verify');
}

=head2 verify_form

    GET /verify

=cut

sub verify_form { shift->render( template => 'user/verify' ) }

=head2 verify

    POST /verify

=cut

sub verify {
    my $self      = shift;
    my $user_info = $self->stash('user_info');

    my $v = $self->validation;
    $v->required('phone')->like(qr/^01[01679]\d{7,8}$/);
    $v->optional('code')->like(qr/^\d{6}$/);

    if ( $v->has_error ) {
        my $failed = $v->failed;
        return $self->error( 400, 'Parameter validation failed: ' . join( ', ', @$failed ) );
    }

    my $phone = $v->param('phone');
    my $code  = $v->param('code');

    my $ui = $self->schema->resultset('UserInfo')->find( { phone => $phone } );
    return $self->error( 400, "중복된 휴대폰번호 입니다: $phone" ) if $ui;

    if ($code) {
        my $verify = delete $self->session->{verify};
        return $self->error( 400, "잘못된 인증번호입니다: $code" ) if $code ne $verify->{code} || '';

        $user_info->update( { phone => $phone } );
        return $self->redirect_to('index');
    }

    $code = String::Random->new->randregex('\d\d\d\d\d\d');
    $self->log->info("[$phone] 열린옷장 인증번호: $code");
    my $sms = $self->sms( $phone, "열린옷장 인증번호: $code" );
    return $self->error( 500, "Failed to send a SMS to $phone" ) unless $sms;

    $self->session( verify => { phone => $phone, code => $code } );
    $self->redirect_to('/verify');
}

1;
