#
# Customized VCL file for serving up a Drupal site with multiple back-ends.
#
# For more information on this VCL, visit the Lullabot article:
# http://www.lullabot.com/articles/varnish-multiple-web-servers-drupal
#

vcl 4.0;
import directors;
import std;

# Define a list of IP addresses or subnets that have privileged access to
# certain files that should not be accessible publicly.
acl privileged {
  "10.0.0.0"/8;
  "172.16.0.0"/12;
  "192.168.0.0"/16;
}

# Define the list of backends (web servers).
backend web1 {
  .host = "192.10.0.1";
  .probe = { .url = "/status.php"; .interval = 5s; .timeout = 1s; .window = 5;.threshold = 3; }
}

backend web2 {
  .host = "192.10.0.2";
  .probe = { .url = "/status.php"; .interval = 5s; .timeout = 1s; .window = 5;.threshold = 3; }
}

sub vcl_init {
  # Define the director that determines how to distribute incoming requests.
  new default_director = directors.round_robin();
  default_director.add_backend(web1);
  default_director.add_backend(web2);
}

# Respond to incoming requests.
sub vcl_recv {

  # A lot of malicious bots pose as IE6. If you do not need IE6 support,
  # prevent this traffic from reaching your backend.
  #if (req.http.User-Agent ~ "MSIE 6.0") {
  #  return(synth(403, "Internet Explorer 6 is not supported."));
  #}

  # Send traffic to default_director to be load balanced.
  set req.backend_hint = default_director.backend();

  # Do not allow outside access to special pages.
  if (req.url ~ "^/(cron|install|status|update|xmlrpc)\.php$" && !client.ip ~ privileged) {
    # Have Varnish throw the error directly.
    return(synth(404, "Page not found."));

    # Use a custom error page that you've defined in Drupal at the path "404".
    # set req.url = "/404";

    # Strip the trailing .php, forcing requests to go through index.php so Drupal
    # can provide its own 404 handling, and will have a relavent URL for things
    # like an automatic search.
    #set req.url = regsuball(req.url, "\.php.*", "");
  }

  # Use anonymous, cached pages if all backends are down.
  if (!std.healthy(req.backend_hint)) {
    unset req.http.Cookie;
  }

  # Do not cache these paths.
  if (req.url ~ "^/status\.php$" ||
      req.url ~ "^/update\.php$" ||
      req.url ~ "^/ooyala/ping$" ||
      req.url ~ "^/admin/build/features" ||
      req.url ~ "^/info/.*$" ||
      req.url ~ "^/flag/.*$" ||
      req.url ~ "^.*/ajax/.*$" ||
      req.url ~ "^.*/ahah/.*$") {
       return (pass);
  }

  # Pipe these paths directly to Apache for streaming.
  if (req.url ~ "^/admin/content/backup_migrate/export") {
    return (pipe);
  }

  # Handle compression correctly. Different browsers send different
  # "Accept-Encoding" headers, even though they mostly all support the same
  # compression mechanisms. By consolidating these compression headers into
  # a consistent format, we can reduce the size of the cache and get more hits.=
  # @see: http:// varnish.projects.linpro.no/wiki/FAQ/Compression
  if (req.http.Accept-Encoding) {
    if (req.http.Accept-Encoding ~ "gzip") {
      # If the browser supports it, we'll use gzip.
      set req.http.Accept-Encoding = "gzip";
    }
    else if (req.http.Accept-Encoding ~ "deflate") {
      # Next, try deflate if it is supported.
      set req.http.Accept-Encoding = "deflate";
    }
    else {
      # Unknown algorithm. Remove it and send unencoded.
      unset req.http.Accept-Encoding;
    }
  }

  # Strip cookies from the following file types for all users.
  # These requests are automatically disqualified from being cached if there are
  # any cookies. Stripping the cookies increases the hit rate.
  if (req.url ~ "(?i)\.(png|gif|jpeg|jpg|ico|swf|css|js|html|htm)(\?[a-z0-9]+)?$") {
    unset req.http.Cookie;
  }
  # Alternatively, strip cookies from directories of static assets.
  #if (req.url ~ "^(/sites/.*)?/(files|libraries|themes)/") {
  #  unset req.http.Cookie;
  #}

  # Remove all cookies that Drupal doesn't need to know about. ANY remaining
  # cookie will cause the request to pass-through to Apache. For the most part
  # we always set the NO_CACHE cookie after any POST request, disabling the
  # Varnish cache temporarily. The session cookie allows all authenticated users
  # to pass through as long as they're logged in.
  if (req.http.Cookie) {
    # 1. Append a semi-colon to the front of the cookie string.
    set req.http.Cookie = ";" + req.http.Cookie;

    # 2. Remove all spaces that appear after semi-colons.
    set req.http.Cookie = regsuball(req.http.Cookie, "; +", ";");

    # 3. Match the cookies we want to keep, adding the space we removed
    #    previously back. (\1) is first matching group in the regsuball.
    set req.http.Cookie = regsuball(req.http.Cookie, ";(S?SESS[a-z0-9]+|NO_CACHE)=", "; \1=");

    # 4. Remove all other cookies, identifying them by the fact that they have
    #    no space after the preceding semi-colon.
    set req.http.Cookie = regsuball(req.http.Cookie, ";[^ ][^;]*", "");

    # 5. Remove all spaces and semi-colons from the beginning and end of the
    #    cookie string.
    set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");

    if (req.http.Cookie == "") {
      # If there are no remaining cookies, remove the cookie header. If there
      # aren't any cookie headers, Varnish's default behavior will be to cache
      # the page.
      unset req.http.Cookie;
    }
    else {
      # If there is any cookies left (a session or NO_CACHE cookie), do not
      # cache the page. Pass it on to Apache directly.
      return (pass);
    }
  }
}

# Routine used to determine the cache key if storing/retrieving a cached page.
sub vcl_hash {
  # Include cookie in cache hash.
  # This check is unnecessary because we already pass on all cookies.
  # if (req.http.Cookie) {
  #   set req.hash += req.http.Cookie;
  # }
}

# Code determining what to do when serving items from the Apache servers.
sub vcl_backend_response {
  # Don't allow these file types to set cookies.
  # Prevent these file types from setting cookies to increase the hit rate.
  # Setting a cookie automatically disqualifies an object from being cached.
  if (bereq.url ~ "(?i)\.(png|gif|jpeg|jpg|ico|swf|css|js|html|htm)(\?[a-z0-9]+)?$") {
    unset beresp.http.set-cookie;
  }
  # Alternatively, specifiy known paths that contain static assets.
  #if (bereq.url ~ "^(/sites/.*)/(files|libraries|themes)/") {
  #  unset beresp.http.set-cookie;
  #}

  # Allow stale-while-revalidate for up to 6 hours
  if (beresp.grace <= 6h) {
    set beresp.grace = 6h;
  }
}

# In the event of an error, show friendlier messages.
sub vcl_backend_error {
  # Redirect to some other URL in the case of a homepage failure.
  #if (req.url ~ "^/?$") {
  #  set obj.status = 302;
  #  set obj.http.Location = "http://backup.example.com/";
  #}

  # Otherwise redirect to the homepage, which will likely be in the cache.
  set beresp.http.Content-Type = "text/html; charset=utf-8";
  synthetic ({"
<html>
<head>
  <title>Page Unavailable</title>
  <style>
    body { background: #303030; text-align: center; color: white; }
    #page { border: 1px solid #CCC; width: 500px; margin: 100px auto 0; padding: 30px; background: #323232; }
    a, a:link, a:visited { color: #CCC; }
    .error { color: #222; }
  </style>
</head>
<body onload="setTimeout(function() { window.location = '/' }, 5000)">
  <div id="page">
    <h1 class="title">Page Unavailable</h1>
    <p>The page you requested is temporarily unavailable.</p>
    <p>We're redirecting you to the <a href="/">homepage</a> in 5 seconds.</p>
    <div class="error">(Error "} + beresp.status + " " + beresp.reason + {")</div>
  </div>
</body>
</html>
"});
  return (deliver);
}
