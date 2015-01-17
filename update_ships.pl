#! /usr/bin/perl

use 5.010;
use strict;
use warnings;
use Data::Dump qw/dd ddx dump/;
use DBI;
use SVG;
use Template;
use File::Temp qw/tempfile/;
use File::Copy qw/move/;
use File::Basename;
use File::Find::Rule;

use Benchmark;
my $t1 = Benchmark->new();

use File::Pid;
my $pidfile = File::Pid->new({file => 'schemaverse-svg.pl.pid' });
if( my $pid = $pidfile->running() ) {
    say $pid, ' running';
    exit;
}
$pidfile->write();

my $config = eval { do 'config.pl' } or die 'config error';

my $dbh = DBI->connect('dbi:Pg:host='.$config->{host}.';database=schemaverse',$config->{user},$config->{pass}) or die "$!";

my $locked = $dbh->selectrow_array(q/
    select status = 'Locked' from status;
/);
die 'Game Locked' if $locked;

my $max_tic = $dbh->selectcol_arrayref(q/select max(tic) from ship_flight_recorder;/)->[0];
die 'no data' unless $max_tic > 1;
say 'max_tic: ' . $max_tic;

if ( $max_tic * $config->{dur} < $config->{min_dur} ) {
    $config->{dur} = $config->{min_dur} / $max_tic;
}
my $round = $dbh->selectcol_arrayref(q/select last_value from round_seq;/)->[0];
my $players = $dbh->selectcol_arrayref(q/
    select player_id from (
        select count(ship_id),ship_id,player_id
        from ship_flight_recorder
        group by ship_id,player_id
        having count(ship_id) > 1
    )a
    group by player_id;
/);
die 'No Players with Valid Moves' unless scalar @$players;

=for comment

Build player_rgb listing

=cut

my $colors = [qw/1f77b4 aec7e8 ff7f0e ffbb78 2ca02c 98df8a d62728 ff9896 9467bd c5b0d5 8c564b c49c94 e377c2 f7b6d2 7f7f7f c7c7c7 bcbd22 dbdb8d 17becf 9edae5/];
my $luma_threshold = 5;
sub check_luma {
    my $rgb = shift;
    return 0 unless $rgb =~ /[[:xdigit:]]{6}/;
    my ( $r,$g,$b ) = $rgb =~ m/[[:xdigit:]]{2}/g;
    return $luma_threshold <
        ( 0.2126 * hex $r ) + ( 0.7152 * hex $g ) + ( 0.0722 * hex $b ); # luma objective
}
my $player_rgb = {};
{
    my $player_colors = $dbh->selectall_arrayref(q/
        select id p, rgb c
        from player_list
        where 1=1
        and rgb is not null
        and rgb ~ '[0-9A-Fa-f]{6}'
        ;
    /, { Slice => {} }) or die "$@";
    for (@$player_colors) {
        next unless( check_luma($_->{c}) );
        $player_rgb->{$_->{p}} = $_->{c};
    }
}
sub get_color {
    my $player = shift;
    unless( defined $player_rgb->{$player} ) {
        return $colors->[ $player % scalar @$colors ];
    }
    else {
        return $player_rgb->{$player};
    }
}

my $h = 750;
my $w = $h;
my $legend_w = 200;
my $svg = SVG->new( width => $w+$legend_w, height => $h );
$svg->title(id=>'document-title')->cdata('Schemaverse | Max Tic '.$max_tic.' | Round '.$round);

my $script = $svg->script(-type=>"text/ecmascript");
$script->CDATA(qq|
    var reload = true;
    function Timer(cb, delay) {
        var timer_id, start, remain = delay;
        this.pause = function() {
            window.clearTimeout(timer_id);
            remain -= new Date() - start;
        };
        this.resume = function() {
            start = new Date();
            timer_id = window.setTimeout(cb, remain);
        };
        this.resume();
    }
    var timer = new Timer( function(){
        document.location.reload(reload);
    }, |.(1000*((($max_tic+1)*$config->{dur})+$config->{delay})).qq| );
    function ship_hi(name,r) {
        r = typeof r !== 'undefined' ? r : 0;
        r = r == 1 ? 2.250 : 1.125;
        var ships = document
            .getElementById('map')
            .getElementsByClassName(name)[0]
            .getElementsByTagName('circle');
        for ( var i = 0, max = ships.length; i < max; i++ ) {
            ships[i].r.baseVal.value = r;
        }
    };
    function pause() {
        document.documentElement.pauseAnimations();
        var button = document.getElementById('pause');
        button.setAttributeNS(null, 'display', 'none');
        button = document.getElementById('play');
        button.setAttributeNS(null, 'display', 'inline');
    }
    function play() {
        document.documentElement.unpauseAnimations();
        var button = document.getElementById('play');
        button.setAttributeNS(null, 'display', 'none');
        button = document.getElementById('pause');
        button.setAttributeNS(null, 'display', 'inline');
    }
    function reload_tgl() {
        if( reload !== true ) {
            reload = true;
            document.getElementById('update-on').setAttributeNS(null, 'display', 'inline');
            document.getElementById('update-off').setAttributeNS(null, 'display', 'none');
        }
        else {
            reload = false;
            document.getElementById('update-on').setAttributeNS(null, 'display', 'none');
            document.getElementById('update-off').setAttributeNS(null, 'display', 'inline');
        }
    }
    function loop_tgl() {
        timer.pause();
        document.getElementById('loop-on').setAttributeNS(null, 'display', 'none');
        document.getElementById('loop-off').setAttributeNS(null, 'display', 'inline');
    }
    function reload_now(r) {
        document.location.reload(reload);
    }
    function planets_hi(out) {
        out = typeof out !== 'undefined' ? out : 0;
        if( out == 1 ) {
            planets_tgl('planets-lo');
        }
        else {
            planets_tgl(name);
        }
    }
    function planets_tgl(name) {
        var planets_lo = document.getElementById('planets-lo'),
            planets_hi = document.getElementById('planets-hi'),
            planets_off = document.getElementById('planets-off'),
            planets_g = document.getElementById('planets');
        switch (name) {
            case 'planets-off':
                planets_lo.setAttributeNS(null, 'display', 'inline');
                planets_hi.setAttributeNS(null, 'display', 'none');
                planets_off.setAttributeNS(null, 'display', 'none');
                planets_g.style.fill = '#333';
                break;
            case 'planets-lo':
                planets_lo.setAttributeNS(null, 'display', 'none');
                planets_hi.setAttributeNS(null, 'display', 'inline');
                planets_off.setAttributeNS(null, 'display', 'none');
                planets_g.style.fill = '#666';
                break;
            case 'planets-hi':
                planets_lo.setAttributeNS(null, 'display', 'none');
                planets_hi.setAttributeNS(null, 'display', 'none');
                planets_off.setAttributeNS(null, 'display', 'inline');
                planets_g.style.fill = '#000';
                break;
        }
    }
|);

my $map = $svg->group( id => 'map' );
$map->rect( id => 'map-bg', x => 1, y => 1, width => $w, height => $h );
my $legend = $svg->group(
    id => 'legend',
    style => {
        'font-size' => '1.4em',
    },
);
$legend->rect(
    id => 'legend-bg',
    x => $w+1, y => 1,
    width => $legend_w, height => $h,
);
$legend->line(
    id => 'legend-border',
    x1 => $w+1, x2 => $w+1,
    y1 => 1, y2 => $h,
    stroke => 'white',
    'stroke-width' => 1,
);
$legend->image(
    x => $w+1, y => $h-100,
    width => 200, height => 73,
    '-href' => 'https://schemaverse.com/images/schemaverse-logo.png',
    id => 'logo',
);
my $legend_e = $legend->group(
    id => 'entries',
    onmouseover => q/
        ship_hi(evt.target.className.baseVal,1);
        evt.target.style.fontSize = '1.3em';
    /,
    onmouseout  => q/
        ship_hi(evt.target.className.baseVal,0);
        evt.target.style.fontSize = '1.2em';
    /,
);


my $scale;
$scale = $dbh->selectcol_arrayref(q\
select m * ceil( v / m ) from (
    select 10 ^ floor(log(
        greatest(max(abs(location_x)),max(abs(location_y)))
    ) ) m,
    greatest(max(abs(location_x)),max(abs(location_y))) v
    from planets
)a
;
\)->[0];

say 'scale: ' . $scale;
my $planets = $dbh->selectall_arrayref(q\
select id,
round( ? / (  ( 2 * ? ) / ( 1e-4 + ? + location[0]::numeric ) ), 4 )::text x,
round( ? - ( ? / ( ( 2 * ? ) / ( 1e-4 + ? + location[1]::numeric ) ) ), 4 )::text y,
conqueror_id c
from planets;
\, { Slice => {} }, $w, $scale, $scale, $h, $h, $scale, $scale ) or die "$!";
# my $conquest = $dbh->selectall_hashref(q\
# select p, string_agg(t,';') t, string_agg(c,';') c, string_agg(v,';') v
# from (
    # select referencing_id p
    # ,tic::text t
    # ,coalesce( player_id_1::text, 0::text ) c
    # ,coalesce( player_id_2::text, 0::text ) v
    # from my_events
    # where public
    # and action = 'CONQUER'
    # order by p,tic
# )a
# group by p
# order by p
# ;

# \, 'p' );

my $conquest = {};
{
    # use Benchmark;
    my $window = 50;
    my $start = 0;
    while( $start < scalar( @$planets ) + $window ) {
        # my $t1 = Benchmark->new();
        my $c = $dbh->selectall_hashref(q\
        select p, string_agg(t,';') t, string_agg(c,';') c, string_agg(v,';') v
        from (
            select referencing_id p
            ,tic::text t
            ,coalesce( player_id_1::text, 0::text ) c
            ,coalesce( player_id_2::text, 0::text ) v
            from my_events
            where public
            and referencing_id >= \ . $start . q\
            and referencing_id < \ . ( $start + $window ) . q\
            and action = 'CONQUER'::char(30)
            order by p,tic
        )a
        group by p
        order by p
        ;

        \, 'p' );
        @$conquest{keys %$c} = values %$c;
        $start += $window;
        # say sprintf( '%.5f s', timediff(Benchmark->new(),$t1)->[0] );
    }
}

my $planet_g = $map->group(
    id => 'planets',
    class => 'planets',
    style => {
        'fill-opacity' => .5,
    },
);
my $planet_r = 1.125;
for my $planet (@$planets) {
    my $id = $planet->{id};
    my $circle;
    if( defined $conquest->{$id} ) {
        my $cv = [ map { '#' . get_color($_) } split ';', $conquest->{$id}->{c} ];
        my $vv = [ map { '#' . get_color($_) } split ';', $conquest->{$id}->{v} ];
        unshift @$cv, $vv->[0];
        push @$cv, $cv->[-1];
        my $tv = [ map { ( $_*$config->{dur} ) / ($max_tic*$config->{dur}) } split ';', $conquest->{$id}->{t} ];
        unshift @$tv, 0;
        push @$tv, 1;
        
        $circle = $planet_g->circle(
            id => 'pl-'.$id,
            cx => $planet->{x}, cy => $planet->{y},
            r => $planet_r,
        );
        $circle->animate(
            -method => 'attribute',
            attributeName => 'fill',
            values => join( ';', @$cv ),
            keyTimes => join( ';', @$tv ),
            begin => '0s',
            dur => ($max_tic*$config->{dur}).'s',
            calcMode => 'discrete',
            fill => 'freeze',
        );
    }
    elsif ( $planet->{c} ) {
        $planet_g->circle(
            id => 'pl-'.$id,
            cx => $planet->{x}, cy => $planet->{y},
            r => $planet_r,
            style => {
                fill => '#'.get_color( $planet->{c} ),
            },
        );
    }
    else {
        $planet_g->circle(
            id => 'pl-'.$id,
            cx => $planet->{x}, cy => $planet->{y},
            r => $planet_r,
            style => {
                fill => '#dedede',
            },
        );
    }
}

my $reload_ctl = $legend->group( id => 'reload-control' );
$reload_ctl->text(
    id => 'loop-off',
    class => 'loop-off',
    x => $w+5, y => $h - 154,
    style => {
        fill => 'white',
        'font-size' => '1.2em',
    },
    onclick => 'reload_now();',
    display => 'none',
)->cdata('reload');
$reload_ctl->text(
    id => 'loop-on',
    class => 'loop-on',
    x => $w+5, y => $h - 154,
    style => {
        fill => 'white',
        'font-size' => '1.2em',
    },
    onclick => 'loop_tgl();',
)->cdata('loop on');
$reload_ctl->text(
    id => 'update-off',
    class => 'update-off',
    x => $w+5, y => $h - 123,
    style => {
        fill => 'white',
        'font-size' => '1.2em',
    },
    onclick => 'reload_tgl();',
    display => 'none',
)->cdata('update off');
$reload_ctl->text(
    id => 'update-on',
    class => 'udpate-on',
    x => $w+5, y => $h - 123,
    style => {
        fill => 'white',
        'font-size' => '1.2em',
    },
    onclick => 'reload_tgl();',
)->cdata('update on');

my $clock_g = $svg->group( id => 'clock' );
$clock_g->text(
    id => 'pause',
    x => $w+5, y => $h - 96,
    style => {
        fill => 'white',
        'font-size' => '1.4em',
    },
    onclick => 'pause();timer.pause();',
)->cdata('pause');
$clock_g->text(
    id => 'play',
    x => $w+5, y => $h - 96,
    style => {
        fill => 'white',
        'font-size' => '1.4em',
    },
    display => 'none',
    onclick => 'play();timer.resume();',
)->cdata('play');
$clock_g->text(
    id => 'round',
    x => $w+$legend_w-111, y => $h-12,
    style => {
        fill => 'white',
        'font-size' => '1.4em',
    },
)->cdata(sprintf('Rd: %5s',$round));
for( 0 .. $max_tic ) {
    my $clock = $clock_g->text(
        id => 'clock'.$_,
        x => $w+10,
        y => $h-12,
        visibility => 'hidden',
        style => {
            fill => 'white',
            'font-size' => '2em',
        },
    )->cdata(sprintf('%4s',$_));
    $clock->animate(
        -method => 'attribute',
        attributeName => 'visibility',
        to => 'visible',
        begin => ( $_ * $config->{dur} ),
        dur => $config->{dur},
        fill => ( $_ == $max_tic ? 'freeze' : 'remove' ),
    );
}

my $paths_sth = $dbh->prepare(q\
    select ship_id s, min(tic) start_tic, max(tic) end_tic,
    string_agg( tic::text, ';') t,
    string_agg( x, ';' ) x, string_agg( y , ';' ) y
    from (
        select ship_id, tic,
        round( \.$w.q\ / ( ( 2 * \.$scale.q\ ) / ( \.$scale.q\ + 1e-4 + location[0]::numeric ) ), 4 )::text x,
        round( \.$h.q\ - ( \.$h.q\ / ( ( 2 * \.$scale.q\ ) / ( 1e-4 + \.$scale.q\ + location[1]::numeric ) ) ), 4 )::text y
        from ship_flight_recorder
        where player_id = ?
        order by ship_id,tic
    )a
    group by ship_id
    having count(*) > 1
    ;
\);
# my $explode_sth = $dbh->prepare(q/
    # select string_agg(concat_ws(',',ship_id_1::text,tic::text),';') from my_events
    # where public and action = 'EXPLODE'
    # and player_id_1 = ?
    # and player_id_2 is null;
# /);

my $i = 0;
for my $player (@$players) {
    $paths_sth->execute( $player );
    my $ships = $paths_sth->fetchall_arrayref({});

    my $p = $dbh->selectcol_arrayref(q/select get_player_username(?);/, undef, $player)->[0];    
    my $text = $legend_e->text(
        id => 'l-'.$player,
        class => $p,
        style => {
            'fill' => '#'.get_color( $player ),
            'font-size' => '1.2em',
        },
        x => $w+5, y => ( ++$i * 24 ),
    )->cdata($p);

    my $svgg = $map->group(
        id => 'p-'.$player,
        class => $p,
        style => {
            'fill' => '#'.get_color( $player ),
        },
    );

    for(@$ships) {
        my $tv = [ split ';', $_->{t} ];
        my $xv = [ split ';', $_->{x} ];
        my $yv = [ split ';', $_->{y} ];
        for ( 0 .. $#$tv ) {
            last unless defined $tv->[$_+1];
            my $gap = $tv->[$_+1] - $tv->[$_];
            if( $gap > 1 ) {
                splice $tv, $_+1, 0, $tv->[$_+1]-1;
                splice $xv, $_+1, 0, $xv->[$_];
                splice $yv, $_+1, 0, $yv->[$_];
            }
        }
        my $ship = $svgg->circle(
            id => 's-'.$_->{s},
            r => 1.125,
        );
        my $begin = ( $config->{dur} * $_->{start_tic} );
        my $ship_dur = ( $config->{dur} * ( $_->{end_tic} - $_->{start_tic} + 1 ) );
        $ship->animate(
            -method => 'attribute',
            attributeName => 'cx',
            values => join( ';', @$xv ),
            begin=> $begin.'s',
            dur => $ship_dur.'s',
            calcMode => 'linear',
            fill => ( $_->{end_tic} == $max_tic ? 'freeze' : 'remove' ),
        );
        $ship->animate(
            -method => 'attribute',
            attributeName => 'cy',
            values => join( ';', @$yv ),
            begin=> $begin.'s',
            dur => $ship_dur.'s',
            calcMode => 'linear',
            fill => ( $_->{end_tic} == $max_tic ? 'freeze' : 'remove' ),
        );
    }
}
my $render = $svg->render();
my $output = $render;
my $dest = 'schemaverse_round'.$round.'.svg';
if ( defined $config->{compress} and $config->{compress} == 1 and eval "require Compress::Zlib" ) {
    $output = Compress::Zlib::memGzip( $render ) or die "$!";
    $dest .= 'z';
}
say '-' x 20;
if ( defined $config->{s3_backend} and $config->{s3_backend} == 1 and eval "require Net::Amazon::S3" ) {
    my $s3 = Net::Amazon::S3->new({
        aws_access_key_id		=> $config->{aws_access_key_id},
        aws_secret_access_key	=> $config->{aws_secret_access_key},
    });
    my $c = Net::Amazon::S3::Client->new( s3 => $s3 );
    my $bucket = $c->bucket( name => $config->{bucket_name} );
    my $object = $bucket->object(
        key => 'viz/'.$dest,
        acl_short => 'public-read',
        content_type => 'image/svg+xml',
        content_encoding => 'gzip',
    );
    my $exists = $object->exists;
    $object->put($output);
    say $object->uri;    
    # update latest dns record for a new round
    unless( $exists ) {
        if( eval "require Net::Amazon::Route53" ) {
            my $route53 = Net::Amazon::Route53->new(
                id => $config->{aws_access_key_id},
                key => $config->{aws_secret_access_key}
            );
            my ( $zone ) = $route53->get_hosted_zones('kwksilver.com.');
            my $record;
            for( @{ $zone->resource_record_sets() } ) {
                next unless $_->type eq 'CNAME' and $_->name eq 'latest.kwksilver.com.';
                $record = $_;
                last;
            }
            my $zone_up = Net::Amazon::Route53::ResourceRecordSet::Change->new(
                route53 => $route53,
                hostedzone => $zone,
                name => 'latest.kwksilver.com.',
                ttl => $record->ttl,
                type => 'CNAME',
                values => [ $object->uri ],
                original_values => $record->values,
            );
            $zone_up->change();
        }
    }
    
    # rebuild directory
    my $t = Template->new() or die $Template::ERROR, "\n";
    my $html = '';
    my $list = [];
    my $stream = $bucket->list({ prefix => 'viz/' });
    until( $stream->is_done ) {
        for my $object ( $stream->items ) {
            next if $object->size == 0;
            next unless $object->key =~ /\.svgz$/;
            push @$list,{
                key => $object->key,
                size => $object->size,
            };
        }
    }
    my $vars = {
        files => [ sort { $b->{key} cmp $a->{key} } @$list ],
        link_base => 'http://www.kwksilver.com/',
        alt_link_base => 'http://www.kwksilver.com.s3.amazonaws.com/',
    };
    $t->process(\*DATA, $vars, \$html ) or die $Template::ERROR, "\n";
    my $obj = $bucket->object(
        key => 'index.html',
        acl_short => 'public-read',
        content_type => 'text/html',
        content_encoding => 'gzip',
    );
    $obj->put( Compress::Zlib::memGzip( $html ) );
    say $obj->uri;
}
if( defined $config->{write_file} and $config->{write_file} == 1 and defined $config->{path} and $config->{path} ne '' ) {
    my ($tmp_fh, $tmp_name) = tempfile();
    print $tmp_fh $output;
    move( $tmp_name, $config->{path}.$dest );
    chmod( 0644, $config->{path}.$dest );
    say $config->{path}.$dest;
    use File::Find::Rule;
    my $files = [ File::Find::Rule->file()
                                ->name( '*.svgz' )
                                ->in( $config->{path} ) ];
    my $index_dest = 'index.html';
    my $t = Template->new() or die $Template::ERROR, "\n";
    my $list = [];
    for ( @$files ) {
        my ( $key ) = fileparse($_);
        push @$list, {
            key => $key,
            size => -s $_,
        };
    }
    my $vars = {
        files => [ sort { $b->{key} cmp $a->{key} } @$list ],
        link_base => 'http://192.168.56.101:11235/',
        alt_link_base => 'http://192.168.56.101:11235/',
    };
    my $html = '';
    $t->process(\*DATA, $vars, \$html ) or die $Template::ERROR, "\n";
    ($tmp_fh, $tmp_name) = tempfile();
    print $tmp_fh $html;
    move( $tmp_name, $config->{path}.$index_dest );
    chmod( 0644, $config->{path}.$index_dest );
    say $config->{path}.$index_dest;
}

say sprintf( '%.5f s', timediff(Benchmark->new(),$t1)->[0] );
$pidfile->remove();

__DATA__
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
        "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>Schemaverse Visualizer Index</title></head>
<body>
<img src="[% link_base _ 'kwksilver.png' %]" />
<h3 style="padding-left: 1.8em">Schemaverse Visualizer Index</h3>
<table>
<thead>
    <tr>
        <th>Name</th>
        <th>Alt Url</th>
        <th>Size</th>
    <tr>
</thead>
<tbody>
    <tr>
        <td><a href="[% link_base _ files.0.key %]">LATEST<a/></td>
        <td><a href="[% alt_link_base _ files.0.key %]">alt<a/></td>
        <td>[% files.0.size %]</td>
    <tr>
[% FOREACH file IN files -%]
    <tr>
        <td><a href="[% link_base _ file.key %]">[% file.key %]<a/></td>
        <td style="width:45px;margin:0 auto;"><a href="[% alt_link_base _ file.key %]">alt</a></td>
        <td>[% file.size %]</td>
    </tr>
[% END -%]
</tbody>
</table>
</body>
</html>