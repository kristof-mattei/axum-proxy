//! A [`PathRewriter`] instance defines a rule to rewrite the request path.
//!
//! A "path" does not include a query. See [`http::uri::Uri`].

use std::borrow::Cow;

use http::header::InvalidHeaderValue;
use http::uri::{Authority, Scheme, Uri};
use http::{Error as HttpError, HeaderMap, HeaderValue, Request};
use regex::{Regex as LibRegex, Replacer};

// RequestRewriter
/// Represents a rule to rewrite a path `/foo/bar/baz` to new one.
///
/// A "path" does not include a query. See [`http::uri::Uri`].
pub trait RequestRewriter {
    fn rewrite_path<'a>(&'a mut self, path: &'a str) -> Cow<'a, str> {
        path.into()
    }

    /// # Errors
    ///
    /// When the headers are invalid
    fn rewrite_headers(
        &mut self,
        _headers: &mut HeaderMap<HeaderValue>,
    ) -> Result<(), InvalidHeaderValue> {
        Ok(())
    }

    /// # Errors
    ///
    /// * When the rewritten path is invalid
    /// * When the headers are invalid
    fn rewrite<B>(
        &mut self,
        request: &mut Request<B>,
        scheme: &Scheme,
        authority: &Authority,
    ) -> Result<(), HttpError> {
        let original_uri = request.uri();
        let path = self.rewrite_path(original_uri.path());

        let rewritten_path = {
            if let Some(query) = original_uri.query() {
                let mut p_and_q = path.into_owned();
                p_and_q.push('?');
                p_and_q.push_str(query);

                p_and_q
            } else {
                path.into()
            }
        };

        let rewritten_uri = Uri::builder()
            .scheme(scheme.clone())
            .authority(authority.clone())
            .path_and_query(rewritten_path)
            .build()?;

        *request.uri_mut() = rewritten_uri;

        self.rewrite_headers(request.headers_mut())?;

        Ok(())
    }
}

pub struct StaticHostRewrite<'a>(pub &'a str);

impl RequestRewriter for StaticHostRewrite<'_> {
    #[inline]
    fn rewrite_headers(
        &mut self,
        headers: &mut HeaderMap<HeaderValue>,
    ) -> Result<(), InvalidHeaderValue> {
        match headers.get_mut("Host") {
            Some(header_value) => *header_value = self.0.try_into()?,
            None => {
                headers.insert("Host", self.0.try_into()?);
            },
        }

        Ok(())
    }
}

/// Identity function, that is, this returns the `path` as is.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, Identity};
/// assert_eq!(Identity.rewrite("foo"), "foo");
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Identity;

impl RequestRewriter for Identity {
    #[inline]
    fn rewrite_path<'a>(&mut self, path: &'a str) -> Cow<'a, str> {
        path.into()
    }
}

/// Returns `self.0` regardless what the `path` is.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, Static};
/// assert_eq!(Static("bar").rewrite("foo"), "bar");
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Static<'a>(pub &'a str);

impl RequestRewriter for Static<'_> {
    #[inline]
    fn rewrite_path<'a>(&'a mut self, _path: &'a str) -> Cow<'a, str> {
        self.0.into()
    }
}

/// `ReplaceAll(old, new)` replaces all matches `old` with `new`.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, ReplaceAll};
/// assert_eq!(ReplaceAll("foo", "bar").rewrite("foofoo"), "barbar");
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReplaceAll<'a>(pub &'a str, pub &'a str);

impl RequestRewriter for ReplaceAll<'_> {
    fn rewrite_path<'a>(&mut self, path: &'a str) -> Cow<'a, str> {
        if path.contains(self.0) {
            path.replace(self.0, self.1).into()
        } else {
            path.into()
        }
    }
}

/// `ReplaceN(old, new, n)` replaces first `n` matches `old` with `new`.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, ReplaceN};
/// assert_eq!(ReplaceN("foo", "bar", 1).rewrite("foofoo"), "barfoo");
/// assert_eq!(ReplaceN("foo", "bar", 3).rewrite("foofoo"), "barbar");
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReplaceN<'a>(pub &'a str, pub &'a str, pub usize);

impl RequestRewriter for ReplaceN<'_> {
    fn rewrite_path<'a>(&mut self, path: &'a str) -> Cow<'a, str> {
        if path.contains(self.0) {
            path.replacen(self.0, self.1, self.2).into()
        } else {
            path.into()
        }
    }
}

/// Trims a prefix if exists.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, TrimPrefix};
/// assert_eq!(TrimPrefix("foo").rewrite("foobarfoo"), "barfoo");
/// assert_eq!(TrimPrefix("bar").rewrite("foobarfoo"), "foobarfoo");
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrimPrefix<'a>(pub &'a str);

impl RequestRewriter for TrimPrefix<'_> {
    fn rewrite_path<'a>(&mut self, path: &'a str) -> Cow<'a, str> {
        if let Some(stripped) = path.strip_prefix(self.0) {
            stripped.into()
        } else {
            path.into()
        }
    }
}

/// Trims a suffix if exists.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, TrimSuffix};
/// assert_eq!(TrimSuffix("foo").rewrite("foobarfoo"), "foobar");
/// assert_eq!(TrimSuffix("bar").rewrite("foobarfoo"), "foobarfoo");
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrimSuffix<'a>(pub &'a str);

impl RequestRewriter for TrimSuffix<'_> {
    fn rewrite_path<'a>(&mut self, path: &'a str) -> Cow<'a, str> {
        if let Some(stripped) = path.strip_suffix(self.0) {
            stripped.into()
        } else {
            path.into()
        }
    }
}

/// Appends a prefix.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, AppendPrefix};
/// assert_eq!(AppendPrefix("foo").rewrite("bar"), "foobar");
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppendPrefix<'a>(pub &'a str);

impl RequestRewriter for AppendPrefix<'_> {
    fn rewrite_path<'a>(&mut self, path: &'a str) -> Cow<'a, str> {
        let mut ret = String::with_capacity(self.0.len() + path.len());
        ret.push_str(self.0);
        ret.push_str(path);
        ret.into()
    }
}

/// Appends a suffix.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, AppendSuffix};
/// assert_eq!(AppendSuffix("foo").rewrite("bar"), "barfoo");
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppendSuffix<'a>(pub &'a str);

impl RequestRewriter for AppendSuffix<'_> {
    fn rewrite_path<'a>(&mut self, path: &'a str) -> Cow<'a, str> {
        let mut ret = String::with_capacity(self.0.len() + path.len());
        ret.push_str(path);
        ret.push_str(self.0);
        ret.into()
    }
}

/// `RegexAll(re, new)` replaces all matches `re` with `new`.
///
/// The type of `new` must implement [`Replacer`].
/// See [`regex`] for details.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, RegexAll};
/// # use regex::Regex;
/// let re = Regex::new(r"(?P<y>\d{4})/(?P<m>\d{2})").unwrap();
/// assert_eq!(
///     RegexAll(re, "$m-$y").rewrite("2021/10/2022/12"),
///     "10-2021/12-2022"
/// );
/// ```
#[derive(Debug, Clone)]
pub struct RegexAll<Rep>(pub LibRegex, pub Rep);

impl<Rep: Replacer> RequestRewriter for RegexAll<Rep> {
    fn rewrite_path<'a>(&mut self, path: &'a str) -> Cow<'a, str> {
        self.0.replace_all(path, self.1.by_ref())
    }
}

/// `RegexN(re, new, n)` replaces first `n` matches `re` with `new`.
///
/// The type of `new` must implement [`Replacer`].
/// See [`regex`] for details.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, RegexN};
/// # use regex::Regex;
/// let re = Regex::new(r"(?P<y>\d{4})/(?P<m>\d{2})").unwrap();
/// assert_eq!(
///     RegexN(re.clone(), "$m-$y", 1).rewrite("2021/10/2022/12"),
///     "10-2021/2022/12"
/// );
/// assert_eq!(
///     RegexN(re, "$m-$y", 3).rewrite("2021/10/2022/12"),
///     "10-2021/12-2022"
/// );
/// ```
#[derive(Debug, Clone)]
pub struct RegexN<Rep>(pub LibRegex, pub Rep, pub usize);

impl<Rep: Replacer> RequestRewriter for RegexN<Rep> {
    fn rewrite_path<'a>(&mut self, path: &'a str) -> Cow<'a, str> {
        self.0.replacen(path, self.2, self.1.by_ref())
    }
}

/// Converts the `path` by a function.
///
/// The type of the function must be `for<'a> FnMut(&'a str) -> String`.
///
/// ```
/// # use axum_proxy::rewrite::{PathRewriter, Func};
/// let f = |path: &str| path.len().to_string();
/// assert_eq!(Func(f).rewrite("abc"), "3");
/// ```
pub struct Func<F>(pub F);

impl<F> RequestRewriter for Func<F>
where
    for<'a> F: FnMut(&'a str) -> String,
{
    fn rewrite_path<'a>(&'a mut self, path: &'a str) -> Cow<'a, str> {
        self.0(path).into()
    }
}

#[cfg(test)]
mod test {
    use pretty_assertions::assert_eq;

    use super::{
        AppendPrefix, AppendSuffix, Func, LibRegex, PathRewriter as _, RegexAll, RegexN,
        ReplaceAll, ReplaceN, Static, TrimPrefix, TrimSuffix,
    };

    #[test]
    fn rewrite_static() {
        let path = "/foo/bar";
        let mut rw = Static("/baz");
        assert_eq!(rw.rewrite_path(path), "/baz");
    }

    #[test]
    fn replace() {
        let path = "/foo/bar/foo/baz/foo";
        let mut rw = ReplaceAll("foo", "FOO");
        assert_eq!(rw.rewrite_path(path), "/FOO/bar/FOO/baz/FOO");

        let path = "/foo/bar/foo/baz/foo";
        let mut rw = ReplaceAll("/foo", "");
        assert_eq!(rw.rewrite_path(path), "/bar/baz");

        let path = "/foo/bar/foo/baz/foo";
        let mut rw = ReplaceN("foo", "FOO", 2);
        assert_eq!(rw.rewrite_path(path), "/FOO/bar/FOO/baz/foo");
    }

    #[test]
    fn trim() {
        let path = "/foo/foo/bar";
        let mut rw = TrimPrefix("/foo");
        assert_eq!(rw.rewrite_path(path), "/foo/bar");

        let path = "/foo/foo/bar";
        let mut rw = TrimPrefix("foo");
        assert_eq!(rw.rewrite_path(path), "/foo/foo/bar");

        let path = "/bar/foo/foo";
        let mut rw = TrimSuffix("foo");
        assert_eq!(rw.rewrite_path(path), "/bar/foo/");

        let path = "/bar/foo/foo";
        let mut rw = TrimSuffix("foo/");
        assert_eq!(rw.rewrite_path(path), "/bar/foo/foo");
    }

    #[test]
    fn append() {
        let path = "/foo/bar";
        let mut rw = AppendPrefix("/baz");
        assert_eq!(rw.rewrite_path(path), "/baz/foo/bar");

        let path = "/foo/bar";
        let mut rw = AppendSuffix("/baz");
        assert_eq!(rw.rewrite_path(path), "/foo/bar/baz");
    }

    #[test]
    fn regex() {
        let path = "/2021/10/21/2021/12/02/2022/01/13";
        let mut rw = RegexAll(
            LibRegex::new(r"(?P<y>\d{4})/(?P<m>\d{2})/(?P<d>\d{2})").unwrap(),
            "$m-$d-$y",
        );
        assert_eq!(rw.rewrite_path(path), "/10-21-2021/12-02-2021/01-13-2022");

        let path = "/2021/10/21/2021/12/02/2022/01/13";
        let mut rw = RegexN(
            LibRegex::new(r"(?P<y>\d{4})/(?P<m>\d{2})/(?P<d>\d{2})").unwrap(),
            "$m-$d-$y",
            2,
        );
        assert_eq!(rw.rewrite_path(path), "/10-21-2021/12-02-2021/2022/01/13");
    }

    #[test]
    fn func() {
        let path = "/abcdefg";
        let mut rw = Func(|path: &str| path.len().to_string());
        assert_eq!(rw.rewrite_path(path), "8");
    }

    #[test]
    fn rewrite_host() {
        let new_host = "example.com";
        let mut rw = StaticHostRewrite(new_host);

        let mut headers = HeaderMap::new();
        headers.append("Host", "example.org".try_into().unwrap());

        rw.rewrite_headers(&mut headers).unwrap();

        assert_eq!(
            headers.get("Host"),
            Some(&HeaderValue::try_from(new_host).unwrap())
        );
    }
}
