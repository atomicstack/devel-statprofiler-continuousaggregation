package Devel::StatProfiler::ContinuousAggregation::Generator;

use strict;
use warnings;
use autodie qw(symlink rename);

use File::Basename qw(basename);
use File::Glob qw(bsd_glob);

use Parallel::ForkManager;

use Devel::StatProfiler::Aggregator;

sub INFO { }
sub WARN { }

sub generate_reports {
    my (%args) = @_;
    my $reports = $args{reports};
    my $processes = $args{processes} // 1;
    my $root_directory = $args{root_directory} // die "Root directory is mandatory";
    my $parts_directory = $args{parts_directory} // $args{root_directory};
    my $aggregator_class = $args{aggregator_class} // 'Devel::StatProfiler::Aggregator';
    my $compress = $args{compress};
    my $pm = Parallel::ForkManager->new($processes);

    my %pending;

    my $move_symlink = sub {
        my ($pid, $exit, $id, $signal, $core, $data) = @_;

        if (--$pending{$data->{aggregation_id}} == 0) {
            my ($aggregation_id, $output_base, $output_final) =
                @{$data}{qw(aggregation_id output_base output_final)};

            INFO "Report for %s generated", $aggregation_id;

            if (-d $output_base) {
                # this dance is to have atomic symlink replacement
                unlink "$output_final.tmp";
                symlink File::Basename::basename($output_base), "$output_final.tmp";
                rename "$output_final.tmp", $output_final;
            }
        }

        return unless $exit || $signal;

        if ($id) {
            WARN "Process %s (PID %d) exited with exit code %d, signal %d", $id, $pid, $exit, $signal;
        } else {
            WARN "PID %d exited with exit code %d, signal %d", $pid, $exit, $signal;
        }
    };
    $pm->run_on_finish($move_symlink);

    for my $report (@$reports) {
        my ($aggregation_id, $fetchers) = @$report;
        my $aggregation_directory = $root_directory . '/reports/' . $aggregation_id;
        my $changed = unlink $aggregation_directory . '/changed';

        next unless $changed;

        my @shards = $aggregator_class->shards($aggregation_directory);
        my $aggregator = $aggregator_class->new(
            root_directory => $aggregation_directory,
            shards         => \@shards,
            flamegraph     => 1,
            serializer     => 'sereal',
            !$fetchers ? () : (
                fetchers     => $fetchers,
            ),
        );
        $aggregator->_load_all_metadata; # so it does not happen for each child
        my $output_final = $root_directory . '/html/' . $aggregation_id;
        my $output_base = $output_final . "." . $$ . "." . time;

        INFO "Processing aggregation %s", $aggregation_id;

        my @report_ids = $aggregator->all_reports;
        $pending{$aggregation_id} = scalar @report_ids;

        for my $report_id (@report_ids) {
            $pm->start("$aggregation_id/$report_id") and next; # do the fork

            INFO "Generating report for %s/%s", $aggregation_id, $report_id;

            my $report = $aggregator->merged_report($report_id, 'map_source');
            my $report_dir = $output_base . '/' . $report_id;
            my $diagnostics = $report->output($report_dir, $compress);
            for my $diagnostic (@$diagnostics) {
                INFO '%s', $diagnostic;
            }

            $pm->finish(0, {
                aggregation_id => $aggregation_id,
                output_base    => $output_base,
                output_final   => $output_final,
            });
        }
    }

    $pm->wait_all_children;

    # delete old reports
    my @paths = bsd_glob $root_directory . '/html/*';
    my %directories; @directories{grep -d $_ && !-l $_, @paths} = ();
    my @symlinks = grep -l $_, @paths;

    for my $symlink (@symlinks) {
        my $target = readlink $symlink;

        delete $directories{$target};
    }

    for my $dead (sort keys %directories) {
        my @info = stat($dead);
        next unless @info; # somebody else was faster

        if ($info[9] > time - 1800) {
            INFO "Not pruning recent report directory '%s'", $dead;
        } else {
            INFO "Pruning report directory '%s'", $dead;

            File::Path::rmtree($dead);
        }
    }
}

1;
