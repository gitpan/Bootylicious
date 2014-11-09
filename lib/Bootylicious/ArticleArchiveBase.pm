package Bootylicious::ArticleArchiveBase;

use strict;
use warnings;

use base 'Mojo::Base';

__PACKAGE__->attr('articles');
__PACKAGE__->attr('year');

my @months = (
    qw/January February March April May July June August September October November December/
);

sub new {
    my $self = shift->SUPER::new(@_);

    return $self->build;
}

sub month_name {
    my $self = shift;

    return '' unless $self->month;

    return $months[$self->month - 1];
}

sub next { shift->articles->next }
sub size { shift->articles->size }

1;
