#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 52;

BEGIN { require FindBin; $ENV{MOJO_HOME} = $ENV{BOOTYLICIOUS_HOME} = "$FindBin::Bin/" }

require "$FindBin::Bin/../bootylicious";

use Test::Mojo;

my $app = app();
$app->secrets(['secret']);

$app->log->level('debug');

my $t = Test::Mojo->new;

# Index page
$t->get_ok('/')->status_is(200)->content_like(qr/booty/);

$t->get_ok('/index.html')->status_is(200)->content_like(qr/booty/);

# Index rss page
$t->get_ok('/index.rss')->status_is(200)->content_like(qr/rss/);

# Archive page
$t->get_ok('/articles.html')->status_is(200)->content_like(qr/Archive/);
$t->get_ok('/articles/2010.html')->status_is(200)->content_like(qr/Archive/);
$t->get_ok('/articles/2010/10.html')->status_is(200)
  ->content_like(qr/Archive/);

# Tags page
$t->get_ok('/tags.html')->status_is(200)->content_like(qr/Tags/);
$t->get_ok('/tags/foo.html')->status_is(200)->content_like(qr/foo/);

# Article Pages
$t->get_ok('/articles/2010/10/foo.html')->status_is(200);

# Page with Markdown
SKIP: {
    skip 'Text::Markdown is required for markdown tests', 3 unless eval { require Text::Markdown; 1; };

$t->get_ok('/pages/markdown.html')->status_is(200)
  ->content_like(qr|<strong>Markdown</strong>|);
 
};

# Page with HTML
$t->get_ok('/pages/html.html')->status_is(200)
  ->content_like(qr|<p>This is HTML</p>|);

# Draft
#$t->get_ok('/draft/2010/10/draft.html')->status_is(200)
  #->content_like(qr/Draft/);

# 404
$t->get_ok('/foo.html')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Articles
$t->get_ok('/articles/foo/foo/foo.html')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Drafts
$t->get_ok('/drafts')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Drafts
$t->get_ok('/drafts/foo.html')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Pages
$t->get_ok('/pages/foo.html')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Pages
$t->get_ok('/../../etc/passwd')->status_is(404)
  ->content_like(qr/The page you are looking for was not found/);

# 404 Pages
$t->get_ok("/articles/2010/10/e,cho.html")->status_is(404);

undef $ENV{MOJO_HOME};
