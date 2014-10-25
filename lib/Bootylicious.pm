package Bootylicious;

BEGIN { use FindBin; use lib "$FindBin::Bin/mojo/lib" }

use Mojolicious::Lite;

use Mojo::Date;
use Mojo::Template;
use Mojo::ByteStream;
use Mojo::Loader;
use Mojo::JSON;
use Mojo::Command;
use Mojo::ByteStream 'b';

use Pod::Simple::HTML;
require File::Basename;

$ENV{LANG} = 'C';
require Time::Piece;
require Time::Local;

our $VERSION = '0.910101';

my %config = (
    perl5lib => '',
    loglevel => 'debug',
    server   => 'cgi',
    author   => $ENV{BOOTYLICIOUS_AUTHOR}
      || 'whoami',
    email => $ENV{BOOTYLICIOUS_EMAIL}
      || '',
    title => $ENV{BOOTYLICIOUS_TITLE}
      || 'Just another blog',
    about => $ENV{BOOTYLICIOUS_ABOUT}
      || 'Perl hacker',
    descr => $ENV{BOOTYLICIOUS_DESCR}
      || 'I do not know if I need this',
    articlesdir => $ENV{BOOTYLICIOUS_ARTICLESDIR}
      || 'articles',
    pagesdir => $ENV{BOOTYLICIOUS_PAGESDIR}
      || 'pages',
    draftsdir => $ENV{BOOTYLICIOUS_DRAFTSDIR}
      || 'drafts',
    publicdir => $ENV{BOOTYLICIOUS_PUBLICDIR}
      || 'public',
    templatesdir => $ENV{BOOTYLICIOUS_TEMPLATESDIR}
      || 'templates',
    footer => $ENV{BOOTYLICIOUS_FOOTER}
      || 'Powered by <a href="http://getbootylicious.org">Bootylicious</a>',
    menu => [
        index   => '/index.html',
        tags    => '/tags.html',
        archive => '/archive.html'
    ],
    theme     => '',
    cuttag    => '[cut]',
    cuttext   => 'Keep reading',
    pagelimit => 10,
    meta      => [],
    css       => [],
    js        => [],
    datefmt   => '%a, %d %b %Y',
    strings   => {
        'archive'             => 'Archive',
        'archive-description' => 'Articles index',
        'tags'                => 'Tags',
        'tags-description'    => 'Tags overview',
        'tag'                 => 'Tag',
        'tag-description'     => 'Articles with tag [_1]',
        'draft'               => 'Draft',
        'permalink-to'        => 'Permalink to',
        'later'               => 'Later',
        'earlier'             => 'Earlier',
        'not-found'           => 'The page you are looking for was not found',
        'error'               => 'Internal error occuried :('
    },
    template_handler => 'ep'
);

if ($ARGV[0] && $ARGV[0] eq 'inflate') {
    my $command = Mojo::Command->new;
    $command->create_rel_dir('templates');

    foreach my $template (
        qw|index.html
        archive.html
        index.rss
        tags.html
        tag.html
        article.html
        page.html
        draft.html
        not_found.html
        exception.html
        layouts/wrapper.html
        |
      )
    {
        my $data = $command->get_data("$template.ep", 'main');

        $command->write_rel_file("templates/$template.ep", $data);
    }

    foreach my $dir (qw/articlesdir draftsdir pagesdir publicdir/) {
        $command->create_rel_dir(config($dir));
    }

    exit(0);
}

app->home->parse($ENV{BOOTYLICIOUS_HOME}) if $ENV{BOOTYLICIOUS_HOME};

_read_config_from_file(app->home->rel_file('bootylicious.conf'));

app->log->level($config{loglevel});

app->renderer->default_handler(config('template_handler'));

app->renderer->add_helper(stash => sub { my $c = shift; $c->stash(@_); });
app->renderer->add_helper(param => sub { my $c = shift; $c->req->param(@_)});
app->renderer->add_helper(url => \&url);
app->renderer->add_helper(url_abs => \&url_abs);
app->renderer->add_helper(config => sub { shift; config(@_) });
app->renderer->add_helper(date => \&date);
app->renderer->add_helper(date_rss => \&date_rss);

# Helpers for plugins
app->renderer->add_helper(get_articles => sub { shift; get_articles(@_) });

app->renderer->add_helper(
    strings => sub {
        my $c = shift;

        my $string = config('strings')->{$_[0]};

        for (my $i = 0; $i < @_; $i++) {
            $string =~ s/\[_$i\]/$_[$i]/;
        }

        return $string;
    }
);

app->plugins->add_hook(
    before_dispatch => sub {
        my ($self, $c) = @_;

        # Make the tests happy
        $c->stash(template_class => __PACKAGE__);

        $c->stash($_ => '') for (qw/title description/);
    }
);

_load_plugins($config{plugins});

sub config {
    if (@_) {
        return $config{$_[0]} if @_ == 1;

        %config = (%config, @_);
    }

    return \%config;
}

ladder sub {
    my $self = shift;

    return 1 if $self->stash->{format};

    return 1 unless $self->req->url;

    return 1 if $self->req->url =~ m{/$};

    my $canonical_location = $self->req->url->to_abs . '.html';

    $self->app->log->debug("Path is not canonical: " . $self->req->url);
    $self->app->log->debug("Redirecting to: " . $canonical_location);

    $self->redirect_to($canonical_location);

    return 0;
};

sub index {
    my $c = shift;

    my $timestamp = $c->req->param('timestamp') || 0;

    my $article = {};
    my ($articles, $pager) =
      get_articles(limit => $config{pagelimit}, timestamp => $timestamp);

    my $last_created  = time;
    my $last_modified = time;
    if (@$articles) {
        $article = $articles->[0];

        $last_created  = $articles->[0]->{created};
        $last_modified = $article->{modified};

        return 1 unless _is_modified($c, $last_modified);
    }

    my $later = 0;

    $c->stash(
        article  => $article,
        articles => $articles,
        pager    => $pager
    );

    $c->res->headers->header('Last-Modified' => Mojo::Date->new($last_modified));

    $c->stash(template => 'index');

    if ($c->stash('format') && $c->stash('format') eq 'rss') {
        $c->stash(
            last_created  => $last_created,
            last_modified => $last_modified,
        );
    }
    else {
        $c->stash(layout => 'wrapper', title => '');
    }

    $c->render;
}

get '/' => \&index => 'root';
get '/index' => \&index => 'index';

get '/archive' => sub {
    my $c = shift;

    my $root = $c->app->home;

    my $last_modified = Mojo::Date->new;

    my ($articles) = get_articles(limit => 0);
    if (@$articles) {
        $last_modified = $articles->[0]->{modified};

        return 1 unless _is_modified($c, $last_modified);
    }

    $c->res->headers->header('Last-Modified' => $last_modified);

    $c->stash(
        layout        => 'wrapper',
        articles      => $articles,
        last_modified => $last_modified,
    );

    $c->render;
} => 'archive';

get '/tags/:tag' => sub {
    my $c = shift;

    my $tag = $c->stash('tag');

    my ($articles) = get_articles(limit => 0);

    $articles = [
        grep {
            grep {m/^\Q$tag\E$/}
              @{$_->{tags}}
          } @$articles
    ];

    unless (@$articles) {
        $c->stash(rendered => 1);
        $c->app->static->serve_404($c);
        return 1;
    }

    my $last_modified = $articles->[0]->{modified};
    return 1 unless _is_modified($c, $last_modified);

    $c->res->headers->header('Last-Modified' => Mojo::Date->new($last_modified));

    my $last_created = $articles->[0]->{created};

    $c->stash(articles => $articles);

    if ($c->stash('format') && $c->stash('format') eq 'rss') {
        $c->stash(
            last_modified => $last_modified,
            last_created  => $last_created,
            template      => 'index'
        );
    }
    else {
        $c->stash(layout => 'wrapper');
    }

    $c->render;
} => 'tag';

get '/tags' => sub {
    my $c = shift;

    my $tags = get_tags();

    $c->stash(layout => 'wrapper',  tags => $tags);

    $c->render;
} => 'tags';

get '/articles/:year/:month/:alias' => sub {
    my $c = shift;

    my $articleid =
      $c->stash('year') . '/' . $c->stash('month') . '/' . $c->stash('alias');

    my ($article, $pager) = get_article($articleid);
    unless ($article) {
        $c->app->log->debug("Article '$articleid' not found");
        $c->stash(rendered => 1);
        $c->app->static->serve_404($c);
        return 1;
    }

    return 1 unless _is_modified($c, $article->{modified});

    $c->stash(article => $article, pager => $pager, layout => 'wrapper');

    $c->res->headers->header(
        'Last-Modified' => Mojo::Date->new($article->{modified}));

    $c->render;
} => 'article';

get '/pages/:pageid' => sub {
    my $c = shift;

    my $pageid = $c->stash('pageid');

    my $page = get_page($pageid);
    unless ($page) {
        $c->stash(rendered => 1);
        $c->app->static->serve_404($c);
        return 1;
    }

    #return 1 unless _is_modified($c, $page->{modified});

    $c->stash(layout => 'wrapper', page => $page);

    $c->res->headers->header(
        'Last-Modified' => Mojo::Date->new($page->{modified}));

    $c->render;
} => 'page';

get '/drafts/:draftid' => sub {
    my $c = shift;

    my $draftid = $c->stash('draftid');

    my $draft = get_draft($draftid);
    unless ($draft) {
        $c->stash(rendered => 1);
        $c->app->static->serve_404($c);
        return 1;
    }

    #return 1 unless _is_modified($c, $page->{modified});

    $c->stash(layout => 'wrapper', draft => $draft);

    $c->res->headers->header(
        'Last-Modified' => Mojo::Date->new($draft->{modified}));

    $c->render;
} => 'draft';

sub theme {
    my $publicdir = app->home->rel_dir($config{publicdir});

    # CSS, JS auto import
    foreach my $type (qw/css js/) {
        $config{$type} =
          [map { s/^$publicdir\///; $_ }
              glob("$publicdir/bootylicious/themes/$config{theme}/*.$type")];
    }
}

sub _read_config_from_file {
    my ($conf_file) = @_;

    app->log->debug("Reading configuration from $conf_file.");

    if (-e $conf_file) {
        if (open FILE, "<", $conf_file) {
            my @lines = <FILE>;
            close FILE;

            my $line = '';
            foreach my $l (@lines) {
                next if $l =~ m/^\s*#/;
                $line .= $l;
            }

            my $json = Mojo::JSON->new;
            my $json_config = $json->decode($line) || {};
            die $json->error if !$json_config && $json->error;

            %config = (%config, %$json_config);

            unshift @INC, $_
              for (
                ref $config{perl5lib} eq 'ARRAY'
                ? @{$config{perl5lib}}
                : $config{perl5lib});
        }
    }
    else {
        app->log->debug("Configuration is not available.");
    }

    $ENV{SCRIPT_NAME} = $config{base} if defined $config{base};

    # set proper templates base dir, if defined
    app->renderer->root(app->home->rel_dir($config{templatesdir}))
        if defined $config{templatesdir};

    # set proper public base dir, if defined
    app->static->root(app->home->rel_dir($config{publicdir}))
        if defined $config{publicdir};
}

sub _load_plugins {
    my $plugins_arrayref = shift;

    my $lib_dir = app->home->rel_dir('lib');
    push @INC, $lib_dir;

    my @plugins;

    my $prev;
    while (my $plugin = shift @$plugins_arrayref) {
        if (ref($plugin) eq 'HASH') {
            next unless $plugins[-1];

            $plugins[-1]->{args} = $plugin;
        }
        else {
            push @plugins, {name => $plugin, args => {}};
        }
    }

    push @{app->plugins->namespaces}, 'Bootylicious::Plugin';
    foreach my $plugin (@plugins) {
        plugin($plugin->{name} => $plugin->{args});
    }
}

sub _is_modified {
    my $c = shift;
    my ($last_modified) = @_;

    my $date = $c->req->headers->header('If-Modified-Since');
    return 1 unless $date;

    return 1 unless Mojo::Date->new($date)->epoch == $last_modified;

    $c->res->code(304);
    $c->stash(rendered => 1);

    return 0;
}

sub get_tags {
    my $tags = {};

    my ($articles) = get_articles(limit => 0);

    foreach my $article (@$articles) {
        foreach my $tag (@{$article->{tags}}) {
            $tags->{$tag}->{count} ||= 0;
            $tags->{$tag}->{count}++;
        }
    }

    return $tags;
}

sub get_articles {
    my %params = @_;
    $params{limit} ||= 0;

    my $root =
      ($config{articlesdir} =~ m/^\//)
      ? $config{articlesdir}
      : app->home->rel_dir($config{articlesdir});

    my $pager = {};

    my @files = sort { $b cmp $a } glob($root . '/*.*');

    if ($params{limit}) {
        my $min = 0;

        if ($params{timestamp}) {
            my $i = 0;
            foreach my $file (@files) {
                File::Basename::basename($file) =~ m/^([^\-]+)-/;

                if ($1 le $params{timestamp}) {
                    $min = $i;
                    last;
                }

                $i++;
            }
        }

        my $max = $min + $params{limit};

        if ($min > $params{limit} - 1 && $files[$min - $params{limit}]) {
            $pager->{prev} = $1
              if File::Basename::basename($files[$min - $params{limit}])
                  =~ m/^([^\-]+)-/;
        }

        if ($max < scalar(@files) && $files[$max]) {
            $pager->{next} = $1
              if File::Basename::basename($files[$max]) =~ m/^([^\-]+)-/;
        }

        @files = splice(@files, $min, $params{limit});
    }

    my @articles;
    foreach my $file (@files) {
        my $data = _parse_article($file);
        next unless $data && %$data;

        push @articles, $data;
    }

    return (\@articles, $pager);
}

sub get_article {
    my $articleid = shift;
    return unless $articleid;

    my ($year, $month, $alias) = split('/', $articleid);
    return unless $year && $month && $alias;

    my $root =
      ($config{articlesdir} =~ m/^\//)
      ? $config{articlesdir}
      : app->home->rel_dir($config{articlesdir});

    my $timestamp_re = qr/^$year$month\d\d(T.*?)?-$alias\./;

    my @files = sort { $b cmp $a } glob($root . '/*.*');

    my $path;

    my ($prev, $next);
    for (my $i = 0; $i <= $#files; $i++) {
        $prev = $files[$i - 1] if $i > 0;
        $next = $files[$i + 1] if $i <= $#files;

        my $basename = File::Basename::basename($files[$i]);
        if ($basename =~ m/$timestamp_re/) {
            $path = $files[$i];
            last;
        }
    }

    return unless $path && -r $path;

    my $pager = {};

    if ($next && $next ne $path) {
        ($pager->{next}) = _parse_article($next);
    }

    if ($prev && $prev ne $path) {
        ($pager->{prev}) = _parse_article($prev);
    }

    return (_parse_article($path), $pager);
}

sub get_draft {
    my $alias = shift;
    return unless $alias;

    my $root =
      ($config{draftsdir} =~ m/^\//)
      ? $config{draftsdir}
      : app->home->rel_dir($config{draftsdir});

    my @files = glob($root . '/' . '*' . $alias . ".*");

    if (@files > 1) {
        app->log->warn('More then one draft is available '
              . 'with the same alias');
    }
    my $path = $files[0];
    return unless $path && -r $path;

    return _parse_article($path);
}

sub get_page {
    my $pageid = shift;
    return unless $pageid;

    my $root =
      ($config{pagesdir} =~ m/^\//)
      ? $config{pagesdir}
      : app->home->rel_dir($config{pagesdir});

    my @files = glob($root . '/' . $pageid . ".*");

    if (@files > 1) {
        app->log->warn('More then one page is available '
              . 'with the same extension');
    }
    my $path = $files[0];
    return unless $path && -r $path;

    return _parse_article($path);
}

sub url {
    my $c = shift;
    my $name = shift;
    my $value = shift;

    if (!defined $name || $name eq '') {
        return '';
    }
    elsif ($name eq 'root') {
        return $c->url_for(index => (format => '', @_));
    }
    elsif ($name eq 'index') {
        return $c->url_for(index => ($value, @_));
    }
    elsif ($name eq 'article') {
        return $c->url_for(
            article => (
                year   => $value->{year},
                month  => $value->{month},
                alias  => $value->{name},
                format => 'html'
            )
        );
    }
    elsif ($name eq 'tag') {
        return $c->url_for(tag => (tag => $value, format => 'html', @_));
    }
    elsif ($name eq 'pager') {
        return $c->url_for('index', format => 'html')
          . "?timestamp=$value";
    }
}

sub url_abs { url(@_)->to_abs }

sub date {
    my $c = shift;
    my $epoch = shift;
    my $fmt = shift;

    $fmt ||= config('datefmt');

    my $t = Time::Piece->gmtime($epoch);

    return b($t->strftime($fmt))->decode('utf-8');
}

sub date_rss {
    my $c = shift;
    my $epoch = shift;

    return Mojo::Date->new($epoch)->to_string;
}

my %_articles;
sub _parse_article {
    my $path = shift;
    return unless $path;

    my $modified = (stat($path))[9];

    return $_articles{$path}
      if $_articles{$path} && $_articles{$path}->{modified} == $modified;

    my ($name, $ext) = ($path =~ m/\/([^\/]+)\.([^.]+)$/);

    my ($year, $month, $day, $hour, $minute, $second);
    if ($name =~ s/(\d\d\d\d)(\d\d)(\d\d)(?:T(\d\d):?(\d\d):?(\d\d))?-//) {
        ($year, $month, $day, $hour, $minute, $second) =
          ($1, $2, $3, ($4 || '00'), ($5 || '00'), ($6 || '00'));

        $second ||= 0;
        $minute ||= 0;
        $hour   ||= 0;
    }
    else {
        ($second, $minute, $hour, $day, $month, $year) =
          gmtime($modified);

        $year += 1900;
        $month += 1;
    }

    my $timestamp =
        $year
      . sprintf('%02d', $month)
      . sprintf('%02d', $day) . 'T'
      . sprintf('%02d', $hour) . ':'
      . sprintf('%02d', $minute) . ':'
      . sprintf('%02d', $second);

    my $created = 0;
    eval {
        $created =
          Time::Local::timegm($second, $minute, $hour, $day, $month - 1,
            $year - 1900);
    };
    if ($@ || $created < 0) {
        app->log->debug("Ignoring $path: wrong timestamp");
        return;
    }

    unless (open FILE, "<:encoding(UTF-8)", $path) {
        app->log->error("Can't open file: $path: $!");
        return;
    }
    my $string = join("", <FILE>);
    close FILE;

    my $parser = _get_parser($ext);
    return unless $parser;

    my $metadata = _parse_metadata(\$string);

    my $cuttag = $config{cuttag};
    my ($head, $tail) = ($string, '');
    my $preview_link = '';
    if ($head =~ s{(.*?)\Q$cuttag\E(?: (.*?))?(?:\n|\r|\n\r)(.*)}{$1}s) {
        $tail = $3;
        $preview_link = $2 || $config{cuttext};
    }

    my $data = $parser->($head, $tail);
    unless ($data) {
        app->log->debug("Ignoring $path: parser error");
        return;
    }

    my $content =
        $data->{tail}
      ? $data->{head} . '<a name="cut"></a>' . $data->{tail}
      : $data->{head};
    my $preview = $data->{tail} ? $data->{head} : '';

    return $_articles{$path} = {
        path            => $path,
        name            => $name,
        created         => $created,
        modified        => $modified,
        timestamp       => $timestamp,
        year            => $year,
        month           => $month,
        day             => $day,
        hour            => $hour,
        minute          => $minute,
        second          => $second,
        title           => $metadata->{title} || $name,
        description     => $metadata->{description} || '',
        link            => $metadata->{link} || '',
        tags            => $metadata->{tags} || [],
        preview         => $preview,
        preview_link    => $preview_link,
        content         => $content
    };
}

my %_parsers;
sub _get_parser {
    my $ext = shift;

    my $parser = \&_parse_article_pod;
    if ($ext eq 'ep') {
        $parser = sub {
            my ($head_string, $tail_string) = @_;

            my $head  = '';
            my $tail  = '';

            my $mt = Mojo::Template->new;

            $head = $mt->render($head_string);

            if ($tail_string) {
                $tail = $mt->render($tail_string);
            }

            return {
                head  => $head,
                tail  => $tail
            };
          }
    }
    elsif ($ext ne 'pod') {
        my $parser_class =
          'Bootylicious::Parser::' . Mojo::ByteStream->new($ext)->camelize;

        if ($_parsers{$parser_class}) {
            $parser = $_parsers{$parser_class};
        }
        else {
            eval "require $parser_class";
            if ($@) {
                app->log->error($@);
                return;
            }
            #my $loader = Mojo::Loader->new;
            #if (my $e = $loader->load($parser_class)) {
                #if (ref $e) {
                    #$c->app->log->error($e);
                #}
                #else {
                    #$c->app->log->error("Unknown parser: $parser_class");
                #}
                #return;
            #}

            $parser = $_parsers{$parser_class} = $parser_class->new->parser_cb;
        }
    }

    return $parser;
}

sub _parse_metadata {
    my $string = shift;

    $$string =~ s/^((.*?)(?:\n\n|\n\r\n\r|\r\r))//s;
    return {} unless $2;

    my $original = $1;
    my $data = $2;

    my $metadata = {};
    while ($data =~ s/^(.*?):\s*(.*?)(?:\n|\n\r|\r|$)//s) {
        my $key = lc $1;
        my $value = $2;

        if ($key eq 'tags') {
            my $tmp = $value || '';
            $value = [];
            @$value = map { s/^\s+//; s/\s+$//; $_ } split(/,/, $tmp);
        }

        $metadata->{$key} = $value;
    }

    unless (%$metadata) {
        $$string = $original . $$string;
    }

    return $metadata;
}

sub _parse_article_pod {
    my ($head_string, $tail_string) = @_;

    my $parser = Pod::Simple::HTML->new;

    $parser->force_title('');
    $parser->html_header_before_title('');
    $parser->html_header_after_title('');
    $parser->html_footer('');

    my $title = '';
    my $head  = '';
    my $tail  = '';

    $parser->output_string(\$head);
    $head_string = "=pod\n\n$head_string";
    eval { $parser->parse_string_document($head_string) };
    return if $@;

    # Hacking
    $head =~ s{<a name='___top' class='dummyTopAnchor'\s*></a>\n}{}g;
    $head =~ s{<a class='u'.*?name=".*?"\s*>(.*?)</a>}{$1}sg;
    $head =~ s{^\s*<h1>NAME</h1>\s*<p>(.*?)</p>}{}sg;
    $title = $1;

    if ($tail_string) {
        $tail_string = "=pod\n$tail_string";
        my $parser = Pod::Simple::HTML->new;

        $parser->force_title('');
        $parser->html_header_before_title('');
        $parser->html_header_after_title('');
        $parser->html_footer('');

        $parser->output_string(\$tail);
        eval { $parser->parse_string_document($tail_string) };
        return if $@;

        $tail =~ s{<a name='___top' class='dummyTopAnchor'\s*></a>\n}{}g;
        $tail =~ s{<a class='u'.*?name=".*?"\s*>(.*?)</a>}{$1}sg;
    }

    my $link = '';
    if ($head =~ s{^\s*<h1>LINK</h1>\s*<p>(.*?)</p>}{}sg) {
        $link = $1;
    }

    my $tags = [];
    if ($head =~ s{^\s*<h1>TAGS</h1>\s*<p>(.*?)</p>}{}sg) {
        my $list = $1; $list =~ s/(?:\r|\n)*//gs;
        @$tags = map { s/^\s+//; s/\s+$//; $_ } split(/,/, $list);
    }

    return {
        title => $title,
        link  => $link,
        tags  => $tags,
        head  => $head,
        tail  => $tail
    };
}

theme if $config{'theme'};

1;

__DATA__

@@ index.html.ep
% stash description => config('descr');
% foreach my $article (@{$articles}) {
    <div class="text">
        <h1 class="title">
%           if ($article->{link}) {
            &raquo;
            <a href="<%= $article->{link} %>">
                <%= $article->{title} %>
            </a>&nbsp;
            <a href="<%= url article => $article %>" title="Permalink to '<%= $article->{title} %>'">
                &#x2605;
            </a>
%           }
%           else {
            <a href="<%= url article => $article %>">
                <%= $article->{title} %>
            </a>
%           }
        </h1>
        <div class="created"><%= date $article->{created} %></div>
        <div class="tags">
%   foreach my $tag (@{$article->{tags}}) {
            <a href="<%= url tag => $tag %>"><%= $tag %></a>
%   }
        </div>
%   if ($article->{preview}) {
        <%== $article->{preview} %>
        <div class="more"> &rarr;
            <a href="<%= url article => $article %>#cut">
                <%= $article->{preview_link} %>
            </a>
        </div>
%   }
%   else {
        <%== $article->{content} %>
%   }
    </div>
% }
    <div id="pager">
% if ($pager->{prev}) {
        &larr; <a href="<%= url pager => $pager->{prev} %>"><%= strings 'later' %></a>
% }
% else {
        <span class="notactive">&larr; <%= strings 'later' %></span>
% }
% if ($pager->{next}) {
        <a href="<%= url pager => $pager->{next} %>"><%= strings 'earlier' %></a> &rarr;
% }
% else {
        <span class="notactive"><%= strings 'earlier' %> &rarr;</span>
% }
    </div>


@@ archive.html.ep
% stash title => strings('archive'), description => strings('archive-description');
% my $tmp;
% my $new = 0;

<div class="text">
    <h1><%= strings 'archive' %></h1>
    <br />
% foreach my $article (@$articles) {
%     if (!$tmp || $article->{year} ne $tmp->{year}) {
    <%== "</ul>" if $tmp %>
    <b><%= $article->{year} %></b>
    <ul>
%     }
    <li>
        <a href="<%= url article => $article %>">
            <%= $article->{title} %>
        </a>
        <br />
        <div class="created"><%= date $article->{created} %></div>
    </li>

%     $tmp = $article;
% }
</div>


@@ index.rss.ep
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xml:base="<%= url_abs 'root' %>"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title><%= config 'title' %></title>
        <link><%= url_abs 'root' %></link>
        <description><%= config 'descr' %></description>
        <pubDate><%= date_rss $last_created %></pubDate>
        <lastBuildDate><%= date_rss $last_created %></lastBuildDate>
        <generator>Mojolicious::Lite</generator>
% foreach my $article (@$articles) {
% my $link = url_abs(article => $article);
    <item>
      <title><%= $article->{title} %></title>
      <link><%= $link %></link>
      <description>
        <%= $article->{preview} || $article->{content} %>
%     if ($article->{link}) {
%     my $permalink = qq|<a href="$link" title="| . strings('permalink-to') . qq| '$article->{title}'">&#x2605;</a>|;
      <%= $permalink %>
%     }
      </description>
% foreach my $tag (@{$article->{tags}}) {
      <category><%= $tag %></category>
% }
      <pubDate><%= date_rss($article->{created}) %></pubDate>
      <guid><%= $link %></guid>
    </item>
% }
    </channel>
</rss>


@@ tags.html.ep
% stash title => strings('tags'), description => strings('tags-description');
<div class="text">
    <h1><%= strings 'tags' %></h1>
    <br />
    <div class="tags">
% foreach my $tag (keys %$tags) {
        <a href="<%= url tag => $tag %>"><%= $tag %></a>
        <sub>(<%= $tags->{$tag}->{count} %>)</sub>
% }
    </div>
</div>


@@ tag.html.ep
% stash title => $tag, description => strings('tag-description', $tag);
<div class="text">
<h1><%= strings 'tag' %> <%= $tag %>
<sup><a href="<%= url tag => $tag, format => 'rss' %>"><img src="data:image/png;base64,
iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJ
bWFnZVJlYWR5ccllPAAAAlJJREFUeNqkU0toU0EUPfPJtOZDm9gSPzWVKloXgiCCInXTRTZVQcSN
LtyF6qILFwoVV+7EjR9oFy7VlSAVF+ouqMWWqCCIrbYSosaARNGmSV7ee+OdyUsMogtx4HBn5t1z
7twz85jWGv8zZHaUmRjlHBnBkRYSCSnog/wzuECZMzxgDNPEW5E0ASHTl4qf6h+KD6iwUpwyuRCw
kcCCNSPoRsNZKeS31D8WTOHLkqoagbQhV+sV1fDqEJQoidSCCMiMjskZU9HU4AAJpJsC0gokTGVD
XnfhA0DRL7+Hn38M/foOeOUzOJEZs+2Cqy5F1iXs3PZLYEGl+ux1NF7eAmpfIXedQOjYbYgdh9tk
Y3oTsDAnNCewPZqF8/SKjdqs+7aCj5wFDkwSlUEvzFgyPK8twNvuBv3GzixgzfgcQmNXqW/68IgE
is+BvRPQ0fXE9eC7Lvy/Cfi5G8DSQ7DkTrCxKbrgJPSTS5TUDQwfgWvIBO0Dvv+bgPFAz12Dzl4E
7p5svpQ9p6HLy9DFF2CD+9sCHpG9DgHHeGAExDglZnLAj09APgts2N089pdFsPjmXwIuHAJk8JKL
rXtuDWtWtQwWiliScFapQJedKxKsVFA0KezVUeMvprcfHDkua6uRzqsylQ2hE2ZPqXAld+/tTfIg
I56VgNG1SDkuhmIb+3tELCLRTYYpRdVDFpwgCJL2fJfXFufLS4Xl6v3z7zBvXkdqUxjJc8M4tC2C
fdDoNe62XPaCaOEBVOjbm++YnSphpuSiZAR6CFQS4h//ZJJD7acAAwCdOg/D5ZiZiQAAAABJRU5E
rkJggg==" alt="RSS" /></a></sup>
</h1>
<br />
% foreach my $article (@$articles) {
        <a href="<%= url article => $article %>">
            <%= $article->{title} %>
        </a>
        <br />
        <div class="created"><%= date $article->{created} %></div>
% }
</div>


@@ article.html.ep
% stash title => $article->{title}, description => $article->{description};
<div class="text">
<h1 class="title">
% if ($article->{link}) {
    &raquo; <a href="<%= $article->{link} %>"><%= $article->{title} %></a>
% } else {
    <%= $article->{title} %>
% }
</h1>
<div class="created"><%= date $article->{created} %>
% if ($article->{created} != $article->{modified}) {
, modified <span class="modified"><%= date $article->{modified} %></span>
% }
</div>
<div class="tags">
% foreach my $tag (@{$article->{tags}}) {
    <a href="<%= url tag => $tag %>"><%= $tag %></a>
% }
</div>
<%== $article->{content} %>
    <div id="pager">
% if ($pager->{prev}) {
        &larr; <a href="<%= url article => $pager->{prev} %>"><%= $pager->{prev}->{title} %></a>&nbsp;|
% }
<a href="<%= url_for 'archive' %>"><%= strings('archive') %></a>
% if ($pager->{next}) {
      |&nbsp;<a href="<%= url article => $pager->{next} %>"><%= $pager->{next}->{title}%></a> &rarr;
% }
    </div>
</div>


@@ page.html.ep
% stash title => $page->{title}, description => $page->{description};
<div class="text">
<h1 class="title">
<%= $page->{title} %>
</h1>
<%== $page->{content} %>
</div>


@@ draft.html.ep
% stash title => $draft->{title}, description => strings('draft');
<div class="text">
<h1 class="title">
<%= $draft->{title} %>
</h1>
<%== $draft->{content} %>
</div>


@@ not_found.html.ep
% stash title => 'Not found', description => 'Not found', layout => 'wrapper';
<div class="error">
<h1>404</h1>
<br />
<%= strings 'not-found' %>
</div>

@@ exception.html.ep
% stash title => 'Not found', description => 'Not found', layout => 'wrapper';
<div class="error">
<h1>500</h1>
<br />
<%= strings 'error' %>
</div>

@@ layouts/wrapper.html.ep
%# $c->res->headers->content_type('text/html; charset=utf-8');
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">

<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
    <head>
        <title><%= $title ? "$title / " : '' %><%= config 'title' %></title>
        <meta http-equiv="Content-type" content="text/html; charset=utf-8" />
% if ($description) {
        <meta name="description" content="<%= $description %>" />
% }
% foreach my $meta (@{config('meta')}) {
        <meta 
% for my $key (keys %$meta) {
<%== "$key=\"$meta->{$key}\" " %>
% }
/>
% }
% foreach my $file (@{config('css')}) {
        <link rel="stylesheet" href="/<%= $file %>" type="text/css" />
% }
% if (!@{config('css')}) {
        <style type="text/css">
            html, body {height: 100%;margin:0}
            body {background: #fff;font-family: "Helvetica Neue", Arial, Helvetica, sans-serif;}
            h1,h2,h3,h4,h5 {font-family: times, "Times New Roman", times-roman, georgia, serif; line-height: 40px; letter-spacing: -1px; color: #444; margin: 0 0 0 0; padding: 0 0 0 0; font-weight: 100;}
            a,a:active {color:#555}
            a:hover{color:#000}
            a:visited{color:#000}
            img{border:0px}
            pre{border:2px solid #ccc;background:#eee;padding:2em;overflow:auto;overflow-y:visible;width:600px;}
            #body {width:65%;min-height:100%;height:auto !important;height:100%;margin:0 auto -6em;}
            #header {text-align:center;padding:2em 0em 0.5em 0em;border-bottom: 1px solid #000}
            h1#title{font-size:3em}
            h2#descr{font-size:1.5em;color:#999}
            span#author {font-weight:bold}
            span#about {font-style:italic}
            #menu {padding-top:1em;text-align:right}
            #content {background:#FFFFFF}
            .created, .modified {color:#999;margin-left:10px;font-size:small;font-style:italic;padding-bottom:0.5em}
            .modified {margin:0px}
            .tags{margin-left:10px;text-transform:uppercase;}
            .text {padding:2em;}
            .text h1.title {font-size:2.5em}
            .error {padding:2em;text-align:center}
            .more {margin-left:10px}
            #pager {text-align:center;padding:2em}
            #pager span.notactive {color:#ccc}
            #subfooter {padding:2em;border-top:#000000 1px solid}
            #footer{width:65%;margin:auto;font-size:80%;text-align:center;padding:2em 0em 2em 0em;border-top:#000000 1px solid;height:2em;}
            .push {height:6em}
        </style>
% }
        <link rel="alternate" type="application/rss+xml" title="<%= config 'title' %>" href="<%= url_abs 'index', format => 'rss' %>" />
    </head>
    <body>
        <div id="body">
            <div id="header">
                <h1 id="title"><a href="<%= url 'root' %>"><%= config 'title' %></a>
                <sup><a href="<%= url 'index', format => 'rss' %>"><img src="data:image/png;base64,
iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJ
bWFnZVJlYWR5ccllPAAAAlJJREFUeNqkU0toU0EUPfPJtOZDm9gSPzWVKloXgiCCInXTRTZVQcSN
LtyF6qILFwoVV+7EjR9oFy7VlSAVF+ouqMWWqCCIrbYSosaARNGmSV7ee+OdyUsMogtx4HBn5t1z
7twz85jWGv8zZHaUmRjlHBnBkRYSCSnog/wzuECZMzxgDNPEW5E0ASHTl4qf6h+KD6iwUpwyuRCw
kcCCNSPoRsNZKeS31D8WTOHLkqoagbQhV+sV1fDqEJQoidSCCMiMjskZU9HU4AAJpJsC0gokTGVD
XnfhA0DRL7+Hn38M/foOeOUzOJEZs+2Cqy5F1iXs3PZLYEGl+ux1NF7eAmpfIXedQOjYbYgdh9tk
Y3oTsDAnNCewPZqF8/SKjdqs+7aCj5wFDkwSlUEvzFgyPK8twNvuBv3GzixgzfgcQmNXqW/68IgE
is+BvRPQ0fXE9eC7Lvy/Cfi5G8DSQ7DkTrCxKbrgJPSTS5TUDQwfgWvIBO0Dvv+bgPFAz12Dzl4E
7p5svpQ9p6HLy9DFF2CD+9sCHpG9DgHHeGAExDglZnLAj09APgts2N089pdFsPjmXwIuHAJk8JKL
rXtuDWtWtQwWiliScFapQJedKxKsVFA0KezVUeMvprcfHDkua6uRzqsylQ2hE2ZPqXAld+/tTfIg
I56VgNG1SDkuhmIb+3tELCLRTYYpRdVDFpwgCJL2fJfXFufLS4Xl6v3z7zBvXkdqUxjJc8M4tC2C
fdDoNe62XPaCaOEBVOjbm++YnSphpuSiZAR6CFQS4h//ZJJD7acAAwCdOg/D5ZiZiQAAAABJRU5E
rkJggg==" alt="RSS" /></a></sup>
                </h1>
                <h2 id="descr"><%= config 'descr' %></h2>
                <span id="author"><%= config 'author' %></span>, <span id="about"><%= config 'about' %></span>
                <div id="menu">
% for (my $i = 0; $i < @{config('menu')}; $i += 2) {
                    <a href="<%= config('menu')->[$i + 1] %>"><%== config('menu')->[$i] %></a>
% }
                </div>
            </div>
            <div id="content">
            <%= content %>
            </div>
            <div class="push"></div>
        </div>
        <div id="footer"><%== config 'footer' %></div>
% foreach my $file (@{config('js')}) {
        <script type="text/javascript" href="/<%= $file %>" />
% }
    </body>
</html>

__END__

=head1 NAME

Bootylicious -- one-file blog on Mojo steroids!

=head1 SYNOPSIS

    $ bootylicious daemon

=head1 DESCRIPTION

Bootylicious is a minimalistic blogging application built on top of
L<Mojolicious::Lite>. You start with just one file, but it is easily extendable
when you add new plugins, templates, css files etc.

=head1 FEATURES

=over

    * filesystem-based storage
    * tags
    * RSS (articles and by tag)
    * paging
    * static pages
    * drafts
    * themes
    * multi-parser support
    * plugins

=back

=head1 CONFIGURATION

Bootylicious can be configured through config file that is placed in the same
directory as C<bootylicious> (or set via BOOTYLICIOUS_HOME env variable) file
and is called C<bootylicious.conf>. It is in JSON format.

    {
        "title" : "my blog title",
        "descr" : "my blog description",
        "author" : "myname",
        "menu" : [
            "item1", "link1",
            "item2", "link2",
            ...
        ],
        ...
    }

If you are using Bootylicious' default templates, there are a number of
configuration options you can set to customize them without ever having to
touch html or template files:

=over 4

=item * author - set the blog author's name. Can also be set via the
BOOTYLICIOUS_AUTHOR environment variable. Default value is "whoami".

=item * about - set the blog author's short description. Can also be set
via the BOOTYLICIOUS_ABOUT environment valiable. Default value is
"Perl hacker".

=item * email - set the blog author's email. Can also be set via the
BOOTYLICIOUS_EMAIL environment variable. Default value is "" (empty).

=item * title - set the blog title. Can also be set via the BOOTYLICIOUS_TITLE
environment variable. Default value is "Just another blog".

=item * descr - set the blog's short description (subtitle). Can also be set
via the BOOTYLICIOUS_DESCR environment variable. Default value is "I do not
know if I need this".

=item * menu - set the blog's menu content. Value should be an array, because
the order matters:

    "menu" : [
        "item1", "link1",
        "item2", "link2",
        ...
    ],

=item * css - loads given css filename from BOOTYLICIOUS_PUBLICDIR/ (see below)
and uses it instead of standard bootylicious css. To load more than one css
file, in the same given order, just pass an array (e.g.:
"css" : [ "foo.css", "bar.css", "baz.css" ]).

=item * js - loads given javascript filename from BOOTYLICIOUS_PUBLICDIR/ (see
below) and uses it on the templates. To load more than one js file, in the same
given order, just pass an array (e.g.: "js" : [ "foo.js", "bar.js", "baz.js" ]).

=item * theme - bootylicious can automatically import css and js files via
themes. Just put those files under PUBLICDIR/bootylicious/themes/my-theme/ and
set this option to "my-theme". Files are loaded in the same order as the
filesystem gives them, usually alphabetic.

=item * footer - sets each page's footer text, to appear in every page.

=back

Also, the following options can be set to change the way bootylicious behaves:

=over 4

=item * articlesdir - set the dir where articles should be fetched from
Can also be set via the BOOTYLICIOUS_ARTICLESDIR environment variable
Default value is "articles".

=item * publicdir - set the dir where bootylicious looks for static objects,
like images, css/js files, etc. Can also be set via the BOOTYLICIOUS_PUBLICDIR
environment variable. Default value is "public".

=item * templatesdir - set the dir where bootylicious looks for template files,
in case you want to override the default ones. Can also be set via the
BOOTYLICIOUS_TEMPLATESDIR environment variable. Default value is "templates".

=item * pagesdir - set the dir where bootylicious looks for static pages.
Default is 'pages'.

=item * draftsdir - set the dir where bootylicious looks for draft pages.
Default is 'drafts'.

=item * cuttag - set the cuttag for parsing the articles. Default is "[cut]".

=item * cuttext - set the link to full article view for articles with a cuttag.
Default is 'Keep reading'.

=item * perl5lib - set any additional lib folders the script should look
into before trying to load Perl 5 modules (ideal for integrating with
L<< local::lib >> and use inside shared hosting environments)

=item * pagelimit - how many articles to show on index page. Default is 10.

=item * meta - html meta tags configuration. Empty by default.

=item * template_handler - what template engine to use and what template files to
search while rendering pages. Default value is 'ep'.

=item * datefmt - date formatting template (strftime). Default value is
'%a, %d %b %Y';

=back

=head1 FILESYSTEM

=head2 ARTICLES

All the articles must be placed under the articlesdir with a name like
20090730-my-new-article.EXTENSION. Based on EXTENSION they are parsed by
different parsers. See parsers section for more information.

The filename format must comply with either of the following:

=over 4

=item * YYYYMMDD-title.EXTENSION

=item * YYYYMMDDTHH:MM:SS-title.EXTENSION

=back

The title may contain dots (".") or dashes ("-") freely.

=head2 PAGES

These are static pages that don't appear on articles page and can be used to
show some static information like documentation, download are, author info etc.

=head2 DRAFTS

These are future articles that you are working on. Just place your drafts under
the draftsdir and keep working. You can look at the preview by pointing your
browser to the draft url. Noone is going to see it, because only you know the
article's title.

=head1 PARSERS

Based on your article's extension (.pod, .ep, .md etc) it is parsed by one of
the bootylicious parsers. By default you can use Mojo::Template or POD formats.
But more parsers are available as third party modules.

You can use any parser at a time. You can have articles written in POD,
Markdown, Wiki etc.

=head2 CONFIGURATION

No configuration is required. That was easy, yeah?

=head2 INTERFACE

    package Bootylicious::Parser::MyNewParser;

    use strict;
    use warnings;

    use base 'Mojo::Base';

    sub parser_cb {
        my $self = shift;

        return sub {
            my ($head_string, $tail_string) = @_;

            my $head  = '';
            my $tail  = '';

            $head = my_new_parser($head_string);

            if ($tail_string) {
                $tail = my_new_parser($tail_string);
            }

            return {
                head  => $head,
                tail  => $tail
            };
          }
    }

    1;

$head_string is everything before the cuttag and $tail_string is everything after
the cuttag.

You must return hashref with parsed head and tail. See
L<Bootylicious::Parser::Md> for a complete example.

=head1 PLUGINS

Bootylicious can be extended by using L<Mojolicious::Plugin> derived third party
plugins.

=head2 CONFIGURATION

Configuration is done in bootylicious config file. Parameters are passed when
loading a plugin.

    # Without params (or with default ones)
    "plugins" : [
        "search",
        "gallery"
    ]

    # With params
    "plugins" : [
        "search", {
            "before_context" : 10
        },
        "gallery", {
            "columns" : 3
        }
    ]

See L<Mojolicious::Plugin> documentation for more details and
L<Bootylicious::Plugin::Search> as an example plugin.

=head1 TEMPLATES

Embedded templates will work just fine, but when you want to have something more
advanced just create a template in templates/ directory with the same name but
optionally with a different extension.

For example there is index.html.ep, thus templates/index.html.ep should be
created with a new content. If you want to use a different base directory for the 
templates, set the C<templatesdir> config option as explained above.

=head1 SUPPORT

=head2 Web

    http://getbootylicious.org/

=head1 DEVELOPMENT

=head2 Repository

    http://github.com/vti/bootylicious/commits/master

=head1 SEE ALSO

L<Mojo> L<Mojolicious> L<Mojolicious::Lite>

=head1 CREDITS

Breno G. de Oliveira

Johannes 'fish' Ziemke

Konstantin Kapitanov

Mirko Westermeier

Sebastian Riedel

Slavik Komarov

=head1 AUTHOR

Viacheslav Tykhanovskyi, C<viacheslav.t@gmail.com>.

=head1 COPYRIGHT

Copyright (C) 2008-2009, Viacheslav Tykhanovskyi.

This program is free software, you can redistribute it and/or modify it under
the same terms as Perl 5.10.

=cut
