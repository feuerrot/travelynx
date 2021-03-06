package Travelynx::Command::database;
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Initialize or upgrade database layout';

has usage => sub { shift->extract_usage };

sub get_schema_version {
	my ($dbh) = @_;
	for my $entry (
		$dbh->selectall_array(qq{select version from schema_version}) )
	{
		return $entry->[0];
	}
}

sub initialize_db {
	my ($dbh) = @_;
	return $dbh->do(
		qq{
			create table schema_version (
				version integer primary key
			);
			create table users (
				id serial not null primary key,
				name varchar(64) not null unique,
				status smallint not null,
				public_level smallint not null,
				email varchar(256),
				token varchar(80),
				password text,
				registered_at timestamptz not null,
				last_login timestamptz not null,
				deletion_requested timestamptz
			);
			create table stations (
				id serial not null primary key,
				ds100 varchar(16) not null unique,
				name varchar(64) not null unique
			);
			create table user_actions (
				id serial not null primary key,
				user_id integer not null references users (id),
				action_id smallint not null,
				station_id int references stations (id),
				action_time timestamptz not null,
				edited not null,
				train_type varchar(16),
				train_line varchar(16),
				train_no varchar(16),
				train_id varchar(128),
				sched_time timestamptz,
				real_time timestamptz,
				route text,
				messages text
			);
			create table pending_mails (
				email varchar(256) not null primary key,
				num_tries smallint not null,
				last_try timestamptz not null
			);
			create table tokens (
				user_id integer not null references users (id),
				type smallint not null,
				token varchar(80) not null,
				primary key (user_id, type)
			);
			insert into schema_version values (2);
		}
	);
}

my @migrations = (

	# v0 -> v1
	sub {
		my ($dbh) = @_;
		return $dbh->do(
			qq{
				alter table user_actions
					add column edited smallint;
				drop table if exists monthly_stats;
				create table journey_stats (
					user_id integer not null references users (id),
					year smallint not null,
					month smallint not null,
					data jsonb not null,
					primary key (user_id, year, month)
				);
				update schema_version set version = 1;
			}
		);
	},

	# v1 -> v2
	sub {
		my ($dbh) = @_;
		return $dbh->do(
			qq{
				update user_actions set edited = 0;
				alter table user_actions
					alter column edited set not null;
				update schema_version set version = 2;
			}
		);
	},
);

sub run {
	my ( $self, $command ) = @_;

	my $dbh = $self->app->dbh;

	if ( $command eq 'setup' ) {
		$dbh->begin_work;
		if ( initialize_db($dbh) ) {
			$dbh->commit;
		}
		else {
			$dbh->rollback;
		}
	}
	elsif ( $command eq 'migrate' ) {
		$dbh->begin_work;
		my $schema_version = get_schema_version($dbh);
		say "Found travelynx schema v${schema_version}";
		if ( $schema_version == @migrations ) {
			say "Database layout is up-to-date";
		}
		for my $i ( $schema_version .. $#migrations ) {
			printf( "Updating to v%d ...\n", $i + 1 );
			if ( not $migrations[$i]($dbh) ) {
				say "Aborting migration; rollback to v${schema_version}";
				$dbh->rollback;
				last;
			}
		}
		if ( get_schema_version($dbh) == @migrations ) {
			$dbh->commit;
		}
	}
	elsif ( $command eq 'has-current-schema' ) {
		if ( get_schema_version($dbh) == @migrations ) {
			say "yes";
		}
		else {
			say "no";
		}
	}
	else {
		$self->help;
	}

	$dbh->disconnect;

}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl database <setup|migrate|has-current-schema>

  Upgrades the database layout to the latest schema.

  Recommended workflow:
  > systemctl stop travelynx
  > TRAVELYNX_DB_HOST=... TRAVELYNX_DB_NAME=... TRAVELYNX_DB_USER=... \
    TRAVELYNX_DB_PASSWORD=... perl index.pl migrate
  > systemctl start travelynx
