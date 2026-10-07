/** Five-minute durable recovery sweep. Schedule via install() during connector setup. */
public without sharing class SfdcDcx_RecoveryScheduler implements Schedulable {
  private static final String NAME_PREFIX = 'SfdcDcx Recovery ';

  public void execute(SchedulableContext context) {
    SfdcDcx_AsyncDispatcher.enqueueNextAutomatic();
  }

  @SuppressWarnings('PMD.ApexCRUDViolation')
  public static void install() {
    Set<String> existing = new Set<String>();
    for (CronTrigger schedule : [
      SELECT CronJobDetail.Name
      FROM CronTrigger
      WHERE CronJobDetail.Name LIKE 'SfdcDcx Recovery %'
      WITH SYSTEM_MODE
    ])
      existing.add(schedule.CronJobDetail.Name);
    for (Integer minute = 0; minute < 60; minute += 5) {
      String name = NAME_PREFIX + minute;
      if (!existing.contains(name))
        System.schedule(
          name,
          '0 ' + minute + ' * * * ?',
          new SfdcDcx_RecoveryScheduler()
        );
    }
  }

  @SuppressWarnings('PMD.ApexCRUDViolation')
  public static void uninstall() {
    for (CronTrigger schedule : [
      SELECT Id, CronJobDetail.Name
      FROM CronTrigger
      WHERE CronJobDetail.Name LIKE 'SfdcDcx Recovery %'
      WITH SYSTEM_MODE
    ])
      System.abortJob(schedule.Id);
  }
}
