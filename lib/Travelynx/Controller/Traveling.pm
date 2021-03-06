package Travelynx::Controller::Traveling;
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use DateTime::Format::Strptime;
use Travel::Status::DE::IRIS::Stations;

sub homepage {
	my ($self) = @_;
	if ( $self->is_user_authenticated ) {
		$self->render(
			'landingpage',
			with_autocomplete => 1,
			with_geolocation  => 1
		);
	}
	else {
		$self->render( 'landingpage', intro => 1 );
	}
}

sub geolocation {
	my ($self) = @_;

	my $lon = $self->param('lon');
	my $lat = $self->param('lat');

	if ( not $lon or not $lat ) {
		$self->render( json => { error => 'Invalid lon/lat received' } );
	}
	else {
		my @candidates = map {
			{
				ds100    => $_->[0][0],
				name     => $_->[0][1],
				eva      => $_->[0][2],
				lon      => $_->[0][3],
				lat      => $_->[0][4],
				distance => $_->[1],
			}
		} Travel::Status::DE::IRIS::Stations::get_station_by_location( $lon,
			$lat, 5 );
		$self->render(
			json => {
				candidates => [@candidates],
			}
		);
	}
}

sub log_action {
	my ($self) = @_;
	my $params = $self->req->json;

	if ( not exists $params->{action} ) {
		$params = $self->req->params->to_hash;
	}

	if ( not $self->is_user_authenticated ) {

		# We deliberately do not set the HTTP status for these replies, as it
		# confuses jquery.
		$self->render(
			json => {
				success => 0,
				error   => 'Session error, please login again',
			},
		);
		return;
	}

	if ( not $params->{action} ) {
		$self->render(
			json => {
				success => 0,
				error   => 'Missing action value',
			},
		);
		return;
	}

	my $station = $params->{station};

	if ( $params->{action} eq 'checkin' ) {

		my ( $train, $error )
		  = $self->checkin( $params->{station}, $params->{train} );

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'checkout' ) {
		my $error = $self->checkout( $params->{station}, $params->{force} );

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'undo' ) {
		my $error = $self->undo( $params->{undo_id} );
		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'cancelled_from' ) {
		my ( undef, $error )
		  = $self->checkin( $params->{station}, $params->{train},
			$self->app->action_type->{cancelled_from} );

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'cancelled_to' ) {
		my $error = $self->checkout( $params->{station}, 1,
			$self->app->action_type->{cancelled_to} );

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'delete' ) {
		my ( $from, $to ) = split( qr{,}, $params->{ids} );
		my $error = $self->delete_journey( $from, $to, $params->{checkin},
			$params->{checkout} );
		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success => 1,
				},
			);
		}
	}
	else {
		$self->render(
			json => {
				success => 0,
				error   => 'invalid action value',
			},
		);
	}
}

sub station {
	my ($self)  = @_;
	my $station = $self->stash('station');
	my $train   = $self->param('train');

	my $status = $self->get_departures($station);

	if ( $status->{errstr} ) {
		$self->render(
			'landingpage',
			with_autocomplete => 1,
			with_geolocation  => 1,
			error             => $status->{errstr}
		);
	}
	else {
		# You can't check into a train which terminates here
		my @results = grep { $_->departure } @{ $status->{results} };

		@results = map { $_->[0] }
		  sort { $b->[1] <=> $a->[1] }
		  map { [ $_, $_->departure->epoch // $_->sched_departure->epoch ] }
		  @results;

		if ($train) {
			@results
			  = grep { $_->type . ' ' . $_->train_no eq $train } @results;
		}

		$self->render(
			'departures',
			ds100   => $status->{station_ds100},
			results => \@results,
			station => $status->{station_name},
			title   => "travelynx: $status->{station_name}",
		);
	}
}

sub redirect_to_station {
	my ($self) = @_;
	my $station = $self->param('station');

	$self->redirect_to("/s/${station}");
}

sub cancelled {
	my ($self) = @_;
	my @journeys = $self->get_user_travels( cancelled => 1 );

	$self->respond_to(
		json => { json => [@journeys] },
		any  => {
			template => 'cancelled',
			journeys => [@journeys]
		}
	);
}

sub history {
	my ($self) = @_;

	$self->render( template => 'history' );
}

sub json_history {
	my ($self) = @_;

	$self->render( json => [ $self->get_user_travels ] );
}

sub yearly_history {
	my ($self) = @_;
	my $year = $self->stash('year');
	my @journeys;
	my $stats;

	if ( not $year =~ m{ ^ [0-9]{4} $ }x ) {
		@journeys = $self->get_user_travels;
	}
	else {
		my $interval_start = DateTime->new(
			time_zone => 'Europe/Berlin',
			year      => $year,
			month     => 1,
			day       => 1,
			hour      => 0,
			minute    => 0,
			second    => 0,
		);
		my $interval_end = $interval_start->clone->add( years => 1 );
		@journeys = $self->get_user_travels(
			after  => $interval_start,
			before => $interval_end
		);
		$stats = $self->get_journey_stats( year => $year );
	}

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template   => 'history_by_year',
			journeys   => [@journeys],
			year       => $year,
			statistics => $stats
		}
	);

}

sub monthly_history {
	my ($self) = @_;
	my $year   = $self->stash('year');
	my $month  = $self->stash('month');
	my @journeys;
	my $stats;
	my @months
	  = (
		qw(Januar Februar März April Mai Juni Juli August September Oktober November Dezember)
	  );

	if ( not( $year =~ m{ ^ [0-9]{4} $ }x and $month =~ m{ ^ [0-9]{1,2} $ }x ) )
	{
		@journeys = $self->get_user_travels;
	}
	else {
		my $interval_start = DateTime->new(
			time_zone => 'Europe/Berlin',
			year      => $year,
			month     => $month,
			day       => 1,
			hour      => 0,
			minute    => 0,
			second    => 0,
		);
		my $interval_end = $interval_start->clone->add( months => 1 );
		@journeys = $self->get_user_travels(
			after  => $interval_start,
			before => $interval_end
		);
		$stats = $self->get_journey_stats(
			year  => $year,
			month => $month
		);
	}

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template   => 'history_by_month',
			journeys   => [@journeys],
			year       => $year,
			month      => $month,
			month_name => $months[ $month - 1 ],
			statistics => $stats
		}
	);

}

sub journey_details {
	my ($self) = @_;
	my ( $uid, $checkout_id ) = split( qr{-}, $self->stash('id') );

	$self->param( journey_id => $checkout_id );

	if ( not( $uid == $self->current_user->{id} and $checkout_id ) ) {
		$self->render(
			'journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my @journeys = $self->get_user_travels(
		uid         => $uid,
		checkout_id => $checkout_id,
		verbose     => 1,
	);
	if (   @journeys == 0
		or not $journeys[0]{completed}
		or $journeys[0]{ids}[1] != $checkout_id )
	{
		$self->render(
			'journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	$self->render(
		'journey',
		error   => undef,
		journey => $journeys[0]
	);
}

sub edit_journey {
	my ($self)      = @_;
	my $checkout_id = $self->param('journey_id');
	my $uid         = $self->current_user->{id};

	if ( not( $uid == $self->current_user->{id} and $checkout_id ) ) {
		$self->render(
			'edit_journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $journey = $self->get_journey(
		uid         => $uid,
		checkout_id => $checkout_id
	);

	if ( not $journey ) {
		$self->render(
			'edit_journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $error = undef;

	if ( $self->param('action') and $self->param('action') eq 'cancel' ) {
		$self->redirect_to("/journey/${uid}-${checkout_id}");
		return;
	}

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $parser = DateTime::Format::Strptime->new(
			pattern   => '%d.%m.%Y %H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);

		$self->app->dbh->begin_work;

		for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival))
		{
			my $datetime = $parser->parse_datetime( $self->param($key) );
			if ( $datetime and $datetime->epoch ne $journey->{$key}->epoch ) {
				$error = $self->update_journey_part(
					$journey->{ids}[0],
					$journey->{ids}[1],
					$key, $datetime->epoch
				);
				if ($error) {
					last;
				}
			}
		}

		if ($error) {
			$self->app->dbh->rollback;
		}
		else {
			$journey = $self->get_journey(
				uid         => $uid,
				checkout_id => $checkout_id,
				verbose     => 1
			);
			$error = $self->journey_sanity_check($journey);
			if ($error) {
				$self->app->dbh->rollback;
			}
			else {
				$self->invalidate_stats_cache( $journey->{checkout} );
				$self->app->dbh->commit;
				$self->redirect_to("/journey/${uid}-${checkout_id}");
				return;
			}
		}

	}

	for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival)) {
		if ( $journey->{$key} and $journey->{$key}->epoch ) {
			$self->param(
				$key => $journey->{$key}->strftime('%d.%m.%Y %H:%M') );
		}
	}

	if ( $journey->{route} ) {
		$self->param( route => join( "\n", @{ $journey->{route} } ) );
	}

	$self->render(
		'edit_journey',
		error   => $error,
		journey => $journey
	);
}

sub add_journey_form {
	my ($self) = @_;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $parser = DateTime::Format::Strptime->new(
			pattern   => '%d.%m.%Y %H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);
		my %opt;

		my @parts = split( qr{\s+}, $self->param('train') );

		if ( @parts == 2 ) {
			@opt{ 'train_type', 'train_no' } = @parts;
		}
		elsif ( @parts == 3 ) {
			@opt{ 'train_type', 'train_line', 'train_no' } = @parts;
		}
		else {
			$self->render(
				'add_journey',
				with_autocomplete => 1,
				error =>
'Zug muss als „Typ Nummer“ oder „Typ Linie Nummer“ eingegeben werden.'
			);
			return;
		}

		for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival))
		{
			my $datetime = $parser->parse_datetime( $self->param($key) );
			if ( not $datetime ) {
				$self->render(
					'add_journey',
					with_autocomplete => 1,
					error => "${key}: Ungültiges Datums-/Zeitformat"
				);
				return;
			}
			$opt{$key} = $datetime;
		}

		for my $key (qw(dep_station arr_station)) {
			$opt{$key} = $self->param($key);
		}

		$self->app->dbh->begin_work;

		my ( $checkin_id, $checkout_id, $error ) = $self->add_journey(%opt);

		$self->app->dbh->rollback;
		$self->render(
			'add_journey',
			with_autocomplete => 1,
			error             => $error
		);
		return;
	}

	$self->render(
		'add_journey',
		with_autocomplete => 1,
		error             => undef
	);
}

1;
