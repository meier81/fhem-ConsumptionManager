use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use ConsumptionManager::CounterHistory qw(cm_counterHistoryCalculateRange cm_counterHistoryCalculateCurrent);
use ConsumptionManager::Meter qw(cm_meterUpdate cm_meterEditChange cm_meterRegisterChange);

my $data = {
    meter => { current => 20, lastUpdate => '2026-11-09 21:31:45' },
    counterHistory => [
        { date => '2026-11-04', counter => 1007, source => 'manual', boundaryExact => 1 },
    ],
    meterChanges => [
        { date => '2026-11-04', effectiveAt => '2026-11-04 08:15:00', oldCounter => 1007, newCounter => 5000 },
        { date => '2026-11-04', effectiveAt => '2026-11-04 12:30:00', oldCounter => 5150, newCounter => 10 },
    ],
};
my $result = cm_counterHistoryCalculateCurrent($data, '2026-11-04');
ok(defined $result, 'two same-day changes can be evaluated');
is($result->{consumption}, 160, '1007 to 5000, 5150 to 10, and 20 yields 160');

$data->{meterChanges}[0]{oldCounter} = 700;
ok(!defined cm_counterHistoryCalculateCurrent($data, '2026-11-04'),
    'implausible removal reading makes consumption unavailable');
$data->{meterChanges}[0]{oldCounter} = 1007;
is(cm_counterHistoryCalculateCurrent($data, '2026-11-04')->{consumption}, 160,
    'correcting historical removal reading restores consumption');

my $missing = {
    meter => { current => 10, lastUpdate => '2026-11-09 00:00:05' },
    counterHistory => [
        { date => '2026-11-08', counter => 6950, source => 'manual', boundaryExact => 1 },
        { date => '2026-11-09', counter => 10, source => 'lastKnownReading',
          observedAt => '2026-11-08 23:59:50',
          capturedAt => '2026-11-09 00:00:02', boundaryExact => 0 },
    ],
    meterChanges => [],
};
ok(!defined cm_counterHistoryCalculateRange($missing, '2026-11-08', '2026-11-09'),
    'unexplained meter drop remains invalid');
push @{$missing->{meterChanges}}, {
    date => '2026-11-08', effectiveAt => '2026-11-08 14:00:00',
    oldCounter => 7000, newCounter => 0,
};
is(cm_counterHistoryCalculateRange($missing, '2026-11-08', '2026-11-09')->{consumption},
    60, 'retained midnight reading permits retrospective correction');

my $stale = {
    %$missing,
    counterHistory => [
        $missing->{counterHistory}[0],
        { date => '2026-11-09', counter => 6950, source => 'lastKnownReading',
          observedAt => '2026-11-08 10:00:00',
          capturedAt => '2026-11-09 00:00:02', boundaryExact => 0 },
    ],
};
ok(!defined cm_counterHistoryCalculateRange($stale, '2026-11-08', '2026-11-09'),
    'pre-change last-known reading is not a valid post-change boundary');

my $live = { meter => { current => 7000, lastUpdate => '2026-11-08 12:00:00',
    lastTimestamp => time() - 120 }, meterChanges => [] };
ok(cm_meterUpdate({}, $live, 10, 0), 'lower physical reading is accepted');
is($live->{meter}{current}, 10, 'lower physical reading is retained');
is($live->{meter}{powerCurrent}, 0, 'unexplained drop produces no negative flow');

$live->{meter}{current} = 1000;
$live->{meter}{lastTimestamp} = time() - 120;
ok(cm_meterUpdate({}, $live, 5000, 0), 'large increase is accepted');
is($live->{meter}{current}, 5000, 'large increase retained without cap');

done_testing();
