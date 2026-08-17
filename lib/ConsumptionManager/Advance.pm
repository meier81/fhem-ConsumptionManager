package ConsumptionManager::Advance;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(
    CM_VERSION
);

use ConsumptionManager::Utils qw(
    cm_today
    cm_dateCompare
    cm_dateSubtractDay
);

our @EXPORT_OK = qw(
    cm_advanceCreate
    cm_advanceEdit
    cm_advanceSetValue
    cm_advanceSave
    cm_advanceCancel
    cm_advanceCurrent
    cm_advanceFind
    cm_advanceValidate
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Advance

=head1 DESCRIPTION

Management of dated monthly advance-payment periods.

=cut

###############################################################################
# Validate an advance-payment period
###############################################################################

sub cm_advanceValidate {
    my ($advance) = @_;

    return 0 unless ref($advance) eq 'HASH';
    return 0 unless exists $advance->{validFrom};
    return 0 unless exists $advance->{amount};

    return 0 unless defined $advance->{validFrom}
        && $advance->{validFrom} =~ /^\d{4}-\d{2}-\d{2}$/;
    return 0 unless defined cm_dateCompare($advance->{validFrom}, $advance->{validFrom});

    if (defined $advance->{validTo} && $advance->{validTo} ne '') {
        return 0 unless $advance->{validTo} =~ /^\d{4}-\d{2}-\d{2}$/;
        return 0 unless defined cm_dateCompare($advance->{validTo}, $advance->{validTo});
        return 0 if cm_dateCompare($advance->{validTo}, $advance->{validFrom}) < 0;
    }

    return 0 unless defined $advance->{amount}
        && $advance->{amount} =~ /^\d+(?:\.\d+)?$/;
    return 0 if $advance->{amount} < 0;

    return 1;
}

###############################################################################
# Create an editor with safe defaults
###############################################################################

sub cm_advanceCreate {
    my ($data) = @_;

    return 0 unless ref($data) eq 'HASH';

    $data->{advanceEditor} = {
        validFrom => cm_today(),
        validTo   => '',
        amount    => 0,
        comment   => '',
    };

    return 1;
}

###############################################################################
# Load an existing advance period into the editor for correction
###############################################################################

sub cm_advanceEdit {
    my ($data, $id) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless defined $id && $id =~ /^\d+$/;
    return 0 unless ref($data->{advances}) eq 'ARRAY';

    for my $advance (@{$data->{advances}}) {
        next unless ref($advance) eq 'HASH';
        next unless defined $advance->{id};
        next unless $advance->{id} == $id;

        my %editor = %{$advance};
        $editor{_editId} = 0 + $id;
        delete $editor{id};
        $data->{advanceEditor} = \%editor;
        return 1;
    }

    return 0;
}

###############################################################################
# Set one editor value
###############################################################################

sub cm_advanceSetValue {
    my ($data, $field, $value) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless ref($data->{advanceEditor}) eq 'HASH';
    return 0 unless keys %{ $data->{advanceEditor} };

    my %allowed = map { $_ => 1 } qw(
        validFrom
        validTo
        amount
        comment
    );

    return 0 unless $allowed{$field};

    if ($field eq 'validFrom' || $field eq 'validTo') {
        if ($field eq 'validTo' && (!defined($value) || $value eq '')) {
            $value = '';
        }
        else {
            return 0 unless defined $value && $value =~ /^\d{4}-\d{2}-\d{2}$/;
            return 0 unless defined cm_dateCompare($value, $value);
        }
    }
    elsif ($field eq 'amount') {
        return 0 unless defined $value && $value =~ /^\d+(?:\.\d+)?$/;
        $value += 0;
    }
    else {
        $value = '' unless defined $value;
    }

    $data->{advanceEditor}{$field} = $value;

    return 1;
}

###############################################################################
# Find the advance valid on a date
###############################################################################

sub cm_advanceFind {
    my ($data, $date) = @_;

    return undef unless ref($data) eq 'HASH';
    return undef unless ref($data->{advances}) eq 'ARRAY';

    $date = cm_today() unless defined $date && $date ne '';
    return undef unless defined cm_dateCompare($date, $date);

    for my $advance (
        sort {
            ($b->{validFrom} // '') cmp ($a->{validFrom} // '')
        } @{ $data->{advances} }
    ) {
        next unless ref($advance) eq 'HASH';
        next unless defined $advance->{validFrom};
        next if $advance->{validFrom} gt $date;

        return $advance
            if !defined($advance->{validTo})
            || $advance->{validTo} eq ''
            || $advance->{validTo} ge $date;
    }

    return undef;
}

###############################################################################
# Return the currently valid advance
###############################################################################

sub cm_advanceCurrent {
    my ($data) = @_;
    return cm_advanceFind($data, cm_today());
}

###############################################################################
# Save editor as a new dated period
###############################################################################

sub cm_advanceSave {
    my ($data) = @_;

    return 0 unless ref($data) eq 'HASH';
    return 0 unless ref($data->{advanceEditor}) eq 'HASH';
    return 0 unless keys %{ $data->{advanceEditor} };

    my %editor = %{ $data->{advanceEditor} };
    my $editId = delete $editor{_editId};
    return 0 unless cm_advanceValidate(\%editor);

    $data->{advances} = [] unless ref($data->{advances}) eq 'ARRAY';

    if (defined $editId) {
        my $index;
        for my $i (0 .. $#{$data->{advances}}) {
            my $entry = $data->{advances}[$i];
            next unless ref($entry) eq 'HASH';
            if (defined $entry->{id} && $entry->{id} == $editId) {
                $index = $i;
                last;
            }
        }
        return 0 unless defined $index;

        for my $i (0 .. $#{$data->{advances}}) {
            next if $i == $index;
            my $entry = $data->{advances}[$i];
            next unless ref($entry) eq 'HASH';
            return 0 if ($entry->{validFrom} // '') eq ($editor{validFrom} // '');
        }

        $editor{id} = 0 + $editId;
        $data->{advances}[$index] = \%editor;
    }
    else {
        my $last;
        if (@{ $data->{advances} }) {
            ($last) = sort { ($b->{validFrom} // '') cmp ($a->{validFrom} // '') }
                grep { ref($_) eq 'HASH' } @{ $data->{advances} };
        }
        if (defined $last) {
            return 0 if cm_dateCompare($editor{validFrom}, $last->{validFrom}) <= 0;
        }

        my $nextId = 1;
        for my $entry (@{ $data->{advances} }) {
            next unless ref($entry) eq 'HASH';
            next unless defined $entry->{id} && $entry->{id} =~ /^\d+$/;
            $nextId = $entry->{id} + 1 if $entry->{id} >= $nextId;
        }
        $editor{id} = $nextId;
        push @{ $data->{advances} }, \%editor;
    }

    @{ $data->{advances} } = sort {
        ($a->{validFrom} // '') cmp ($b->{validFrom} // '')
    } @{ $data->{advances} };

    for my $i (0 .. $#{$data->{advances}} - 1) {
        my $entry = $data->{advances}[$i];
        my $next  = $data->{advances}[$i + 1];
        next unless ref($entry) eq 'HASH' && ref($next) eq 'HASH';
        if (!defined($entry->{validTo}) || $entry->{validTo} eq ''
            || $entry->{validTo} ge $next->{validFrom}) {
            my $validTo = cm_dateSubtractDay($next->{validFrom});
            return 0 unless defined $validTo;
            $entry->{validTo} = $validTo;
        }
    }

    $data->{advanceEditor} = {};
    return 1;
}

###############################################################################
# Cancel current editor
###############################################################################

sub cm_advanceCancel {
    my ($data) = @_;

    return 0 unless ref($data) eq 'HASH';
    $data->{advanceEditor} = {};

    return 1;
}

1;
