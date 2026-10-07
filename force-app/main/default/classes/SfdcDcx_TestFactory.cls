/** Shared synthetic fixtures for ScanForce Open application tests. */
@IsTest
public class SfdcDcx_TestFactory {
  public static final String INVOICE_RESULT =
    '{"jobId":"remote_1","status":"completed","documentType":"invoice",' +
    '"result":{"documentNumber":"INV-001","total":1240.5,"issueDate":"2026-09-30","paid":false,' +
    '"supplier":{"name":"Example Supplies Ltd","taxId":"XX-0000"},' +
    '"lines":[{"description":"Paper","quantity":2,"amount":20.5},{"description":"Toner","quantity":1,"amount":1220}]},' +
    '"warnings":["LOW_CONFIDENCE"],"reviewUrl":null}';

  public static User createUser(String alias, List<String> permissionSets) {
    return createUser(alias, permissionSets, 'Standard User');
  }

  public static User createUser(
    String alias,
    List<String> permissionSets,
    String profileName
  ) {
    Profile profile = [
      SELECT Id
      FROM Profile
      WHERE Name = :profileName
      LIMIT 1
    ];
    User user = new User(
      Alias = alias,
      Email = alias + '@example.invalid',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Synthetic ' + alias,
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = profile.Id,
      TimeZoneSidKey = 'Europe/Warsaw',
      Username = alias +
        '.' +
        UserInfo.getOrganizationId() +
        '.' +
        System.now().getTime() +
        '@example.invalid'
    );
    insert user;
    List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
    for (PermissionSet permissionSet : [
      SELECT Id
      FROM PermissionSet
      WHERE Name IN :permissionSets
    ])
      assignments.add(
        new PermissionSetAssignment(
          AssigneeId = user.Id,
          PermissionSetId = permissionSet.Id
        )
      );
    insert assignments;
    return user;
  }

  public static User userByAlias(String alias) {
    return [SELECT Id FROM User WHERE Alias = :alias LIMIT 1];
  }

  public static ContentVersion createFile(
    String title,
    String extension,
    Id linkedRecordId
  ) {
    ContentVersion file = new ContentVersion(
      Title = title,
      PathOnClient = title + '.' + extension,
      VersionData = Blob.valueOf('%PDF synthetic ScanForce Open test bytes'),
      FirstPublishLocationId = linkedRecordId
    );
    insert file;
    return [
      SELECT Id, ContentDocumentId, Title, FileExtension
      FROM ContentVersion
      WHERE Id = :file.Id
    ];
  }

  /** Submits through the real authorized service without enqueueing work. */
  public static Id submit(
    Id contentVersionId,
    Id sourceRecordId,
    String documentType
  ) {
    SfdcDcx_Worker.suppressEnqueue = true;
    SfdcDcx_Submit.Input input = new SfdcDcx_Submit.Input();
    input.contentVersionId = contentVersionId;
    input.sourceRecordId = sourceRecordId;
    input.documentType = documentType;
    SfdcDcx_Submit.Output output = SfdcDcx_Submit.submit(
      new List<SfdcDcx_Submit.Input>{ input }
    )[0];
    System.assert(
      output.success,
      'Fixture submission failed: ' + output.errorCode
    );
    return output.processingJobId;
  }

  /** Test-only state seeding; production code transitions jobs only through the Domain. */
  public static void seed(
    Id jobId,
    String status,
    String resultJson,
    String reviewUrl,
    String errorCode
  ) {
    Database.update(
      new SfdcDcx_Processing_Job__c(
        Id = jobId,
        Status__c = status,
        Provider_Job_Id__c = 'remote_' + String.valueOf(jobId).right(6),
        Attempt_Count__c = 2,
        Result_JSON__c = resultJson,
        Review_URL__c = reviewUrl,
        Error_Code__c = errorCode,
        Completed_At__c = status == 'Completed' ? System.now() : null
      ),
      AccessLevel.SYSTEM_MODE
    );
  }

  public static SfdcDcx_Field_Mapping__mdt mapping(
    String name,
    String documentType,
    String targetObject,
    String path,
    String field,
    Boolean active
  ) {
    return (SfdcDcx_Field_Mapping__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'DeveloperName' => name,
          'Document_Type__c' => documentType,
          'Target_Object__c' => targetObject,
          'Result_Path__c' => path,
          'Target_Field__c' => field,
          'Active__c' => active
        }
      ),
      SfdcDcx_Field_Mapping__mdt.class
    );
  }
}
