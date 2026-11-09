package ConsumptionManager::CounterHistory;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(cm_counterHistoryCalculateRange cm_counterHistoryCalculateCurrent);

# Physical meter arithmetic. Never infer an unknown counter from a virtual
# offset. Legacy date-only replacements are ambiguous on a boundary date.
sub _number {
    my ($v) = @_;
    return defined($v) && !ref($v)
        && $v =~ /^\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
}

sub _date {
    my ($v) = @_;
    return defined($v) && $v =~ /^\d{4}-\d{2}-\d{2}$/;
}

sub _boundary {
    my ($data, $date) = @_;
    return undef unless ref($data->{counterHistory}) eq 'ARRAY';
    my @entries = grep {
        ref($_) eq 'HASH' && ($_->{date} // '') eq $date
            && _number($_->{counter})
    } @{ $data->{counterHistory} };
    return undef unless @entries == 1;
    my $entry = $entries[0];
    # A snapshot taken after the intended boundary cannot establish it.
    return undef if defined($entry->{capturedAt})
        && $entry->{capturedAt} lt ($date . ' 00:00:00');
    # A stale sample may be used as a last-known estimate, but a sample
    # from after midnight cannot be represented as the midnight value.
    # Explicitly estimated post-restart readings are allowed, with provenance.
    return undef if ($entry->{source} // '') eq 'lastKnownReading'
        && ($entry->{observedAt} // '') ge ($date . ' 00:00:00');
    # A carried-forward reading is not a valid midnight boundary if a
    # documented replacement happened after the last actual observation.
    if (($entry->{boundaryExact} // 0) == 0) {
        my $observed = $entry->{observedAt} // '';
        my $boundaryAt = "$date 00:00:00";
        if ($observed ne '') {
            for my $change (@{ $data->{meterChanges} // [] }) {
                next unless ref($change) eq 'HASH';
                my $at = $change->{effectiveAt} // '';
                return undef if $at ne '' && $at gt $observed
                    && $at le $boundaryAt;
            }
        }
    }
    return $entry;
}

sub _calculate {
    my ($data, $startAt, $endAt, $opening, $closing, $source) = @_;
    return undef unless _number($opening) && _number($closing);
    return undef unless ref($data->{meterChanges}) eq 'ARRAY';
    my @changes;
    for my $change (@{ $data->{meterChanges} }) {
        return undef unless ref($change) eq 'HASH';
        my $date = $change->{date} // '';
        return undef unless _date($date);
        my $at = $change->{effectiveAt};
        if (defined($at) && length($at)) {
            return undef unless $at =~ /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
                && substr($at, 0, 10) eq $date;
        } else {
            # A date-only change is only unambiguous when strictly inside
            # the interval, and there is no boundary on its calendar day.
            return undef if $date ge substr($startAt, 0, 10)
                && $date le substr($endAt, 0, 10);
            next;
        }
        # Replacements exactly on a boundary require a documented side:
        # the opening reading is on the new meter, the closing reading
        # is on the old meter. Without that proof, reject the interval.
        return undef if $at eq $startAt || $at eq $endAt;
        next if $at lt $startAt || $at gt $endAt;
        return undef unless _number($change->{oldCounter})
            && _number($change->{newCounter});
        push @changes, { %$change, _at => $at };
    }
    @changes = sort { $a->{_at} cmp $b->{_at} } @changes;
    my ($counter, $from, $total) = (0 + $opening, $startAt, 0);
    my @segments;
    my $lastAt = '';
    for my $change (@changes) {
        return undef if $change->{_at} eq $lastAt;
        my $old = 0 + $change->{oldCounter};
        return undef if $old < $counter;
        my $used = $old - $counter;
        push @segments, { startAt => $from, endAt => $change->{_at},
            startCounter => $counter, endCounter => $old,
            consumption => $used };
        $total += $used;
        $counter = 0 + $change->{newCounter};
        $from = $change->{_at};
        $lastAt = $from;
    }
    return undef if $closing < $counter;
    my $used = $closing - $counter;
    $total += $used;
    push @segments, { startAt => $from, endAt => $endAt,
        startCounter => $counter, endCounter => 0 + $closing,
        consumption => $used };
    return { startDate => substr($startAt,0,10),
        endDate => substr($endAt,0,10), startAt => $startAt,
        endAt => $endAt, consumption => $total, segments => \@segments,
        source => $source };
}

sub cm_counterHistoryCalculateRange {
    my ($data, $startDate, $endDate) = @_;
    return undef unless ref($data) eq 'HASH'
        && _date($startDate) && _date($endDate) && $startDate lt $endDate;
    my $start = _boundary($data, $startDate);
    my $end = _boundary($data, $endDate);
    return undef unless $start && $end;
    return _calculate($data, "$startDate 00:00:00",
        "$endDate 00:00:00", $start->{counter}, $end->{counter},
        'physicalBoundaries');
}

sub cm_counterHistoryCalculateCurrent {
    my ($data, $startDate) = @_;
    return undef unless ref($data) eq 'HASH' && _date($startDate)
        && ref($data->{meter}) eq 'HASH'
        && _number($data->{meter}{current});
    my $start = _boundary($data, $startDate);
    return undef unless $start;
    my $observed = $data->{meter}{lastUpdate} // '';
    return undef unless $observed =~ /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/;
    my $boundaryAt = "$startDate 00:00:00";
    if ($observed lt $boundaryAt) {
        # A last-known midnight snapshot can be newer than the last actual
        # observation. Only carry it forward as zero consumption when the
        # unchanged live counter confirms that same known value.
        return undef unless 0 + $data->{meter}{current} == 0 + $start->{counter};
        # No observed sample after the opening boundary: a documented
        # replacement invalidates the apparent zero-usage assumption.
        for my $change (@{ $data->{meterChanges} // [] }) {
            next unless ref($change) eq 'HASH';
            my $at = $change->{effectiveAt} // '';
            return undef if $at ne '' && $at gt $observed
                && $at <= $boundaryAt;
        }
        return _calculate($data, $boundaryAt, $boundaryAt,
            $start->{counter}, $start->{counter},
            'physicalBoundaryAndStaleReading');
    }
    return _calculate($data, $boundaryAt, $observed,
        $start->{counter}, $data->{meter}{current},
        'physicalBoundaryAndLiveReading');
}

1;
