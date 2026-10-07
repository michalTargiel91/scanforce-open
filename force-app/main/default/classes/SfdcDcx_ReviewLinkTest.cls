@IsTest
private class SfdcDcx_ReviewLinkTest {
  private static final String PROVIDER = 'https://provider.example.com/connect';

  @IsTest
  static void providersMaySendPathsAndHttpsUrls() {
    for (
      String value : new List<String>{
        '/review/abc',
        '/analyze?record=0f4c-11&tab=fields#top',
        '/',
        'https://provider.example.com/review/1',
        'https://provider.example.com:8443/r?id=1',
        'https://review.example.com',
        '/' + 'x'.repeat(254)
      }
    )
      System.assert(SfdcDcx_ReviewLink.isAcceptable(value), value);
    System.assert(SfdcDcx_ReviewLink.isAcceptable(null));
  }

  @IsTest
  static void dangerousAndMalformedValuesAreRejected() {
    for (
      String value : new List<String>{
        'javascript:alert(1)',
        'JavaScript:alert(1)',
        'data:text/html;base64,PHNjcmlwdD4=',
        'vbscript:msgbox(1)',
        'http://provider.example.com/review/1',
        'HTTPS://provider.example.com/review/1',
        'ftp://provider.example.com/review',
        '//evil.example.com/review',
        '/\\evil.example.com',
        '\\\\evil.example.com',
        'https://user:secret@provider.example.com/review/1',
        'https://provider.example.com@evil.example.com/',
        'https:///review',
        'https://-bad.example.com/',
        'https://provider.example.com:123456/',
        'https://provider.example.com/review 1',
        '/review/1\nSet-Cookie:x',
        '/review/<script>',
        'review/1',
        '',
        ' /review/1',
        '/' + 'x'.repeat(255)
      }
    )
      System.assert(!SfdcDcx_ReviewLink.isAcceptable(value), value);
  }

  @IsTest
  static void onlyTheProviderOriginIsOpened() {
    System.assertEquals(
      'https://provider.example.com/review/abc',
      SfdcDcx_ReviewLink.resolve('/review/abc', PROVIDER)
    );
    System.assertEquals(
      'https://provider.example.com/r/1?x=y',
      SfdcDcx_ReviewLink.resolve(
        'https://provider.example.com/r/1?x=y',
        PROVIDER
      )
    );
    System.assertEquals(
      'https://PROVIDER.example.com:443/r/1',
      SfdcDcx_ReviewLink.resolve(
        'https://PROVIDER.example.com:443/r/1',
        PROVIDER
      ),
      'Host case and the default port do not change the origin'
    );
    for (
      String foreign : new List<String>{
        'https://review.example.com/r/1',
        'https://provider.example.com.evil.example.com/r/1',
        'https://provider.example.com:8443/r/1',
        'https://example.com/r/1',
        'javascript:alert(1)',
        '//provider.example.com/r/1'
      }
    )
      System.assertEquals(
        null,
        SfdcDcx_ReviewLink.resolve(foreign, PROVIDER),
        foreign
      );
  }

  @IsTest
  static void portsArePartOfTheOrigin() {
    String endpoint = 'https://provider.example.com:8443/connect';
    System.assertEquals(
      'https://provider.example.com:8443/review/1',
      SfdcDcx_ReviewLink.resolve('/review/1', endpoint)
    );
    System.assertEquals(
      'https://provider.example.com:8443/r',
      SfdcDcx_ReviewLink.resolve(
        'https://provider.example.com:8443/r',
        endpoint
      )
    );
    System.assertEquals(
      null,
      SfdcDcx_ReviewLink.resolve('https://provider.example.com/r', endpoint)
    );
  }

  @IsTest
  static void nothingOpensWithoutAKnownProviderOrigin() {
    System.assertEquals(null, SfdcDcx_ReviewLink.resolve('/review/1', null));
    System.assertEquals(
      null,
      SfdcDcx_ReviewLink.resolve('https://provider.example.com/r', null)
    );
    System.assertEquals(
      null,
      SfdcDcx_ReviewLink.resolve('/review/1', 'http://provider.example.com')
    );
    System.assertEquals(null, SfdcDcx_ReviewLink.resolve(null, PROVIDER));
  }
}
