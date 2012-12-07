############################################################
#                                                          #
#                          hprose                          #
#                                                          #
# Official WebSite: http://www.hprose.com/                 #
#                   http://www.hprose.net/                 #
#                   http://www.hprose.org/                 #
#                                                          #
############################################################

############################################################
#                                                          #
# Hprose/Reader.pm                                         #
#                                                          #
# Hprose Reader class for perl                             #
#                                                          #
# LastModified: Dec 7, 2012                                #
# Author: Ma Bingyao <andot@hprfc.com>                     #
#                                                          #
############################################################
package Hprose::Reader;

use strict;
use warnings;
use bytes;
use Encode;
use Error;
use Math::BigInt;
use Math::BigFloat;
use Tie::RefHash;
use Hprose::Exception;
use Hprose::Tags;
use Hprose::ClassManager;

my $check_tag = sub {
    my $tag = shift;
    if ($tag != shift) {
        throw Hprose::Exception("'$tag' is not the expected tag");
    }
};

my $check_tags = sub {
    my ($tag, $expect_tags) = @_;
    if (index($expect_tags, $tag) < 0) {
        throw Hprose::Exception("Tag '$expect_tags' expected, but '$tag' found in stream");
    }
    $tag;
};

my $getc = sub {
    my $buffer;
    return $buffer if shift->read($buffer, 1, 0);
};

my $readuntil = sub {
    my ($stream, $tag) = @_;
    my $s = '';
    my $c;
    while ($stream->read($c, 1, 0) && $c ne $tag) { $s .= $c; }
    $s;
};

my $readint = sub {
    my ($stream, $tag) = @_;
    my $s = $readuntil->($stream, $tag);
    return 0 if ($s eq '');
    int($s);
};

my $readutf8 = sub {
    my ($stream, $len) = @_;
    return '' if ($len == 0);
    my $str = '';
    my $pos = 0;
    for (my $i = 0; $i < $len; ++$i) {
        my $char;
        $stream->read($char, 1, 0);
        my $ord = ord($char);
        $str .= $char;
        ++$pos;
        if ($ord < 0x80) {
            next;
        }
        elsif (($ord & 0xE0) == 0xC0) {
            $stream->read($str, 1, $pos);
            ++$pos;
        }
        elsif (($ord & 0xF0) == 0xE0) {
            $stream->read($str, 2, $pos);
            $pos += 2;
        }
        elsif (($ord & 0xF8) == 0xF0) {
            $stream->read($str, 3, $pos);
            $pos += 3;
            ++$i;
        }
    }
    $str;
};

my $read_string = sub {
    my $stream = shift;
    my $len = $readint->($stream, Hprose::Tags->Quote);
    my $str = $readutf8->($stream, $len);
    $getc->($stream);
    $str;
};

my %unserializeMethod = (
    '0' => sub { 0; },
    '1' => sub { 1; },
    '2' => sub { 2; },
    '3' => sub { 3; },
    '4' => sub { 4; },
    '5' => sub { 5; },
    '6' => sub { 6; },
    '7' => sub { 7; },
    '8' => sub { 8; },
    '9' => sub { 9; },
    Hprose::Tags->Integer => \&read_integer,
    Hprose::Tags->Long => \&read_long,
    Hprose::Tags->Double => \&read_double,
    Hprose::Tags->NaN => \&read_nan,
    Hprose::Tags->Infinity => \&read_infinity,
    Hprose::Tags->Null => \&read_null,
    Hprose::Tags->Empty => \&read_empty,
    Hprose::Tags->True => sub { 1 == 1; },
    Hprose::Tags->False => sub { 1 != 1; },
    Hprose::Tags->Date => \&read_date,
    Hprose::Tags->Time => \&read_time,
    Hprose::Tags->Bytes => \&read_bytes,
    Hprose::Tags->UTF8Char => \&read_utf8char,
    Hprose::Tags->String => \&read_string,
    Hprose::Tags->Guid => \&read_guid,
    Hprose::Tags->List => \&read_array,
    Hprose::Tags->Map => \&read_hash,
    Hprose::Tags->Class => sub { my $self = shift; $self->read_class; $self->read_object_with_tag; },
    Hprose::Tags->Object => \&read_object,
    Hprose::Tags->Ref => \&read_ref,
    Hprose::Tags->Error => sub { throw Hprose::Exception(shift->read_string_with_tag); },
);

use constant {
    ExpectBoolean => Hprose::Tags->True . Hprose::Tags->False,
    ExpectDate => Hprose::Tags->Date . Hprose::Tags->Ref,
    ExpectTime => Hprose::Tags->Time . Hprose::Tags->Ref,
    ExpectBytes => Hprose::Tags->Bytes . Hprose::Tags->Ref,
    ExpectString => Hprose::Tags->String . Hprose::Tags->Ref,
    ExpectGuid => Hprose::Tags->Guid . Hprose::Tags->Ref,
    ExpectList => Hprose::Tags->List . Hprose::Tags->Ref,
    ExpectMap => Hprose::Tags->Map . Hprose::Tags->Ref,
    ExpectObject => Hprose::Tags->Class . Hprose::Tags->Object . Hprose::Tags->Ref,
};

sub new {
    my ($class, $stream) = @_;
    my $self = bless {
        stream => $stream,
        classref => [],
        ref => [],
    }, $class;
}

sub check_tag {
    $check_tag->($getc->(shift->{stream}), shift());
}

sub check_tags {
    $check_tags->($getc->(shift->{stream}), shift());
}

sub unserialize {
    my $self = shift;
    my $tag;
    if ($self->{stream}->read($tag, 1, 0)) {
        if (exists($unserializeMethod{$tag})) {
            $unserializeMethod{$tag}($self);
        }
        else {
            throw Hprose::Exception("Unexpected serialize tag '$tag' in stream");
        }
    }
    else {
        throw Hprose::Exception("No byte found in stream");
    }
}

sub read_integer {
    $readint->(shift->{stream}, Hprose::Tags->Semicolon);
}

sub read_integer_with_tag {
    my $self = shift;
    my $tag;
    $self->{stream}->read($tag, 1, 0);
    return int($tag) if (($tag ge '0') && ($tag le '9'));
    $check_tag->($tag, Hprose::Tags->Integer);
    $self->read_integer;
}

sub read_long {
    Math::BigInt->new($readuntil->(shift->{stream}, Hprose::Tags->Semicolon));
}

sub read_long_with_tag {
    my $self = shift;
    my $tag;
    $self->{stream}->read($tag, 1, 0);
    return Math::BigInt->new($tag) if (($tag ge '0') && ($tag le '9'));
    $check_tag->($tag, Hprose::Tags->Long);
    $self->read_long;
}

sub read_double {
    Math::BigFloat->new($readuntil->(shift->{stream}, Hprose::Tags->Semicolon));
}

sub read_double_with_tag {
    my $self = shift;
    my $tag;
    $self->{stream}->read($tag, 1, 0);
    return Math::BigFloat->new($tag) if (($tag ge '0') && ($tag le '9'));
    $check_tag->($tag, Hprose::Tags->Double);
    $self->read_double;
}

sub read_nan {
    Hprose::Numeric->NaN;
}

sub read_nan_with_tag {
    my $self = shift;
    $self->check_tag(Hprose::Tags->NaN);
    $self->read_nan;
}

sub read_infinity {
    ($getc->(shift->{stream}) eq Hprose::Tags->Neg) ?
    Hprose::Numeric->NInf :
    Hprose::Numeric->Inf;
}

sub read_infinity_with_tag {
    my $self = shift;
    $self->check_tag(Hprose::Tags->Infinity);
    $self->read_infinity;
}

sub read_null {
    undef;
}

sub read_null_with_tag {
    my $self = shift;
    $self->check_tag(Hprose::Tags->Null);
    $self->read_null;
}

sub read_empty {
    '';
}

sub read_empty_with_tag {
    my $self = shift;
    $self->check_tag(Hprose::Tags->Empty);
    $self->read_empty;
}

sub read_boolean_with_tag {
    shift->check_tags(ExpectBoolean) eq Hprose::Tags->True;
}

sub read_date {
    my $self = shift;
    my $stream = $self->{stream};
    my ($year, $month, $day, $hour, $minute, $second, $nanosecond) = (1970, 1, 1, 0, 0, 0, 0);
    $stream->read($year, 4, 0);
    $stream->read($month, 2, 0);
    $stream->read($day, 2, 0);
    my $tag;
    $stream->read($tag, 1, 0);
    if ($tag eq Hprose::Tags->Time) {
        $stream->read($hour, 2, 0);
        $stream->read($minute, 2, 0);
        $stream->read($second, 2, 0);
        $stream->read($tag, 1, 0);
        if ($tag eq Hprose::Tags->Point) {
            $stream->read($nanosecond, 3, 0);
            $stream->read($tag, 1, 0);
            if (($tag ge '0') && ($tag le '9')) {
                $nanosecond .= $tag;
                $stream->read($nanosecond, 2, 4);
                $stream->read($tag, 1, 0);
                if (($tag ge '0') && ($tag le '9')) {
                    $nanosecond .= $tag;
                    $stream->read($nanosecond, 2, 7);
                    $stream->read($tag, 1, 0);
                }
                else {
                    $nanosecond *= 1000;
                }
            }
            else {
                $nanosecond *= 1000000;
            }
        }
    }
    my $time_zone = ($tag eq Hprose::Tags->UTC) ? 'UTC' : 'floating';
    my $date = DateTime->new(
        year       => $year,
        month      => $month,
        day        => $day,
        hour       => $hour,
        minute     => $minute,
        second     => $second,
        nanosecond => $nanosecond,
        time_zone  => $time_zone,
    );
    my $ref = $self->{ref};
    $ref->[scalar(@$ref)] = $date;
}

sub read_date_with_tag {
    my $self = shift;
    ($self->check_tags(ExpectDate) eq Hprose::Tags->Ref) ?
    $self->read_ref :
    $self->read_date;
}

sub read_time {
    my $self = shift;
    my $stream = $self->{stream};
    my ($hour, $minute, $second, $nanosecond) = (0, 0, 0, 0);
    $stream->read($hour, 2, 0);
    $stream->read($minute, 2, 0);
    $stream->read($second, 2, 0);
    my $tag;
    $stream->read($tag, 1, 0);
    if ($tag eq Hprose::Tags->Point) {
        $stream->read($nanosecond, 3, 0);
        $stream->read($tag, 1, 0);
        if (($tag ge '0') && ($tag le '9')) {
            $nanosecond .= $tag;
            $stream->read($nanosecond, 2, 4);
            $stream->read($tag, 1, 0);
            if (($tag ge '0') && ($tag le '9')) {
                $nanosecond .= $tag;
                $stream->read($nanosecond, 2, 7);
                $stream->read($tag, 1, 0);
            }
            else {
                $nanosecond *= 1000;
            }
        }
        else {
            $nanosecond *= 1000000;
        }
    }
    my $time_zone = ($tag eq Hprose::Tags->UTC) ? 'UTC' : 'floating';
    my $time = DateTime->new(
        year       => 1970,
        month      => 1,
        day        => 1,
        hour       => $hour,
        minute     => $minute,
        second     => $second,
        nanosecond => $nanosecond,
        time_zone  => $time_zone,
    );
    my $ref = $self->{ref};
    $ref->[scalar(@$ref)] = $time;
}

sub read_time_with_tag {
    my $self = shift;
    ($self->check_tags(ExpectTime) eq Hprose::Tags->Ref) ?
    $self->read_ref :
    $self->read_time;
}

sub read_bytes {
    my $self = shift;
    my $stream = $self->{stream};
    my $len = $readint->($stream, Hprose::Tags->Quote);
    my $bytes;
    $stream->read($bytes, $len, 0);
    $getc->($stream);
    my $ref = $self->{ref};
    $ref->[scalar(@$ref)] = $bytes;
}

sub read_bytes_with_tag {
    my $self = shift;
    ($self->check_tags(ExpectBytes) eq Hprose::Tags->Ref) ?
    $self->read_ref :
    $self->read_bytes;
}

sub read_utf8char {
    $readutf8->(shift->{stream}, 1);
}

sub read_utf8char_with_tag {
    my $self = shift;
    $self->check_tag(Hprose::Tags->UTF8Char);
    $self->read_utf8char;
}


sub read_string {
    my $self = shift;
    my $str = $read_string->($self->{stream});
    my $ref = $self->{ref};
    $ref->[scalar(@$ref)] = $str;
}

sub read_string_with_tag {
    my $self = shift;
    ($self->check_tags(ExpectString) eq Hprose::Tags->Ref) ?
    $self->read_ref :
    $self->read_string;
}
sub read_guid {
    my $self = shift;
    my $stream = $self->{stream};
    $getc->($stream);
    my $guid;
    $stream->read($guid, 36, 0);
    $getc->($stream);
    my $ref = $self->{ref};
    $ref->[scalar(@$ref)] = $guid;
}
sub read_guid_with_tag {
    my $self = shift;
    ($self->check_tags(ExpectGuid) eq Hprose::Tags->Ref) ?
    $self->read_ref :
    $self->read_guid;
}

sub read_array {
    my $self = shift;
    my $stream = $self->{stream};
    my $ref = $self->{ref};
    my $list = [];
    $ref->[scalar(@$ref)] = $list;
    my $count = $readint->($stream, Hprose::Tags->Openbrace);
    $list->[$_] = $self->unserialize foreach (0..$count - 1);
    $getc->($stream);
    $list;
}

sub read_array_with_tag {
    my $self = shift;
    ($self->check_tags(ExpectList) eq Hprose::Tags->Ref) ?
    $self->read_ref :
    $self->read_array;
}

sub read_hash {
    my $self = shift;
    my $stream = $self->{stream};
    my $ref = $self->{ref};
    my $hash;
    tie %$hash, 'Tie::RefHash';
    $ref->[scalar(@$ref)] = $hash;
    my $count = $readint->($stream, Hprose::Tags->Openbrace);
    $hash->{$self->unserialize} = $self->unserialize foreach (0..$count - 1);
    $getc->($stream);
    $hash;
}

sub read_hash_with_tag {
    my $self = shift;
    ($self->check_tags(ExpectMap) eq Hprose::Tags->Ref) ?
    $self->read_ref :
    $self->read_hash;
}
sub read_class {
    my $self = shift;
    my $stream = $self->{stream};
    my $classname = $read_string->($stream);
    my $count = $readint->($stream, Hprose::Tags->Openbrace);
    my $fields = [];
    $fields->[$_] = $self->read_string foreach (0..$count - 1);
    $getc->($stream);
    my $class = Hprose::ClassManager->get_class($classname);
    my $classref = $self->{classref};
    $classref->[scalar(@$classref)] = [$class, $fields, $count];
}

sub read_object {
    my $self = shift;
    my $stream = $self->{stream};
    my $classref = $self->{classref};
    my ($class, $fields, $count) = @{$classref->[$readint->($stream, Hprose::Tags->Openbrace)]};
    my $object = $class->new;
    my $ref = $self->{ref};
    $ref->[scalar(@$ref)] = $object;
    $object->{$fields->[$_]} = $self->unserialize foreach (0..$count - 1);
    $getc->($stream);
    $object;
}
sub read_object_with_tag {
    my $self = shift;
    my $tag = $self->check_tags(ExpectObject);
    return $self->read_ref if ($tag eq Hprose::Tags->Ref);
    if ($tag eq Hprose::Tags->Class) {
        $self->read_class;
        $self->read_object_with_tag;
    }
    else {
        $self->read_object;
    }
}
sub read_ref {
    my $self = shift;
    $self->{ref}->[$readint->($self->{stream}, Hprose::Tags->Semicolon)];
}

sub reset {
    my $self = shift;
    undef @{$self->{ref}};
    undef @{$self->{classref}};
}

1;