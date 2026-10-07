/**
 * Trust policy for provider-supplied review links (protocol section 3). They
 * are untrusted input used only for browser navigation; Salesforce never
 * fetches them.
 *
 * A provider may send null, a provider-relative path ("/review/1?tab=fields")
 * or an absolute https URL. Anything else is an invalid response: other
 * schemes, user info, backslashes, spaces, control characters, a
 * protocol-relative "//host" form or more than 255 characters.
 *
 * Users are only ever offered a link on the configured provider origin: a
 * relative path joined to that origin, or an absolute URL with exactly that
 * origin. Links to any other origin are stored but never opened.
 */
public with sharing class SfdcDcx_ReviewLink {
  public static final Integer MAX_LENGTH = 255;
  // RFC 3986 path, query and fragment characters (no brackets, quotes, spaces or backslash).
  private static final String URL_CHAR = '[A-Za-z0-9._~:/?#@!$&\'()*+,;=%-]';
  private static final String FIRST_PATH_CHAR = '[A-Za-z0-9._~:?#@!$&\'()*+,;=%-]';
  private static final String HOST = '[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?';

  /** True when a provider may send this value; null means "no review link". */
  public static Boolean isAcceptable(String value) {
    return value == null || isRelative(value) || isAbsolute(value);
  }

  /** A path on the provider origin: one leading slash, never "//" or "/\". */
  public static Boolean isRelative(String value) {
    return value != null &&
      value.length() <= MAX_LENGTH &&
      Pattern.matches('/(' + FIRST_PATH_CHAR + URL_CHAR + '*)?', value);
  }

  public static Boolean isAbsolute(String value) {
    return value != null &&
      value.length() <= MAX_LENGTH &&
      Pattern.matches(
        'https://' + HOST + '(:[0-9]{1,5})?([/?#]' + URL_CHAR + '*)?',
        value
      );
  }

  /**
   * The link to open for a stored review value, or null when there is none or
   * it is not on the provider origin (scheme, host and port compared).
   */
  public static String resolve(String value, String providerEndpoint) {
    String origin = SfdcDcx_ProviderConnection.origin(providerEndpoint);
    if (origin == null || value == null)
      return null;
    if (isRelative(value))
      return origin + value;
    if (!isAbsolute(value))
      return null;
    Matcher authority = Pattern.compile('https://([^/?#]+)').matcher(value);
    authority.lookingAt();
    return SfdcDcx_ProviderConnection.canonicalOrigin(
        'https://' + authority.group(1)
      ) == origin
      ? value
      : null;
  }
}
