/** Single authority for all processing-state transitions. */
public with sharing class SfdcDcx_ProcessingJobDomain {
  public class DomainException extends Exception {
  }
  private static final Set<String> TERMINAL = new Set<String>{
    'Completed',
    'Failed',
    'Cancelled',
    'Timed Out'
  };
  private static final Map<String, Set<String>> TRANSITIONS = new Map<String, Set<String>>{
    'Queued' => new Set<String>{
      'Queued',
      'Processing',
      'Review Required',
      'Completed',
      'Failed',
      'Cancelled',
      'Timed Out'
    },
    'Submitting' => new Set<String>{
      'Processing',
      'Review Required',
      'Completed',
      'Failed',
      'Cancelled',
      'Timed Out'
    },
    'Processing' => new Set<String>{
      'Processing',
      'Review Required',
      'Completed',
      'Failed',
      'Cancelled',
      'Timed Out'
    },
    'Review Required' => new Set<String>{
      'Review Required',
      'Completed',
      'Failed',
      'Cancelled'
    },
    'Completed' => new Set<String>(),
    'Failed' => new Set<String>{
      'Queued',
      'Processing',
      'Review Required',
      'Completed',
      'Failed',
      'Cancelled',
      'Timed Out'
    },
    'Cancelled' => new Set<String>{
      'Queued',
      'Processing',
      'Review Required',
      'Completed',
      'Failed',
      'Cancelled',
      'Timed Out'
    },
    'Timed Out' => new Set<String>{
      'Queued',
      'Processing',
      'Review Required',
      'Completed',
      'Failed',
      'Cancelled',
      'Timed Out'
    }
  };

  public static Boolean isTerminal(String state) {
    return TERMINAL.contains(state);
  }

  public static Boolean isAutomaticStop(String state) {
    return isTerminal(state) || state == 'Review Required';
  }

  public static Boolean canTransition(String fromState, String toState) {
    return TRANSITIONS.containsKey(fromState) &&
      TRANSITIONS.get(fromState).contains(toState);
  }

  public static void transition(
    SfdcDcx_Processing_Job__c change,
    String currentState,
    String targetState
  ) {
    if (!canTransition(currentState, targetState))
      throw new DomainException(
        'Forbidden processing transition: ' +
          currentState +
          ' -> ' +
          targetState
      );
    change.Status__c = targetState;
  }

  public static void markProcessing(
    SfdcDcx_Processing_Job__c c,
    String fromState
  ) {
    transition(c, fromState, 'Processing');
  }
  public static void markReviewRequired(
    SfdcDcx_Processing_Job__c c,
    String fromState
  ) {
    transition(c, fromState, 'Review Required');
  }
  public static void complete(SfdcDcx_Processing_Job__c c, String fromState) {
    transition(c, fromState, 'Completed');
  }
  public static void cancel(SfdcDcx_Processing_Job__c c, String fromState) {
    transition(c, fromState, 'Cancelled');
  }
  public static void timeOut(SfdcDcx_Processing_Job__c c, String fromState) {
    transition(c, fromState, 'Timed Out');
    error(c, 'POLLING_TIMEOUT');
  }
  public static void fail(
    SfdcDcx_Processing_Job__c c,
    String fromState,
    String code
  ) {
    transition(c, fromState, 'Failed');
    error(c, code);
  }
  public static void error(SfdcDcx_Processing_Job__c c, String code) {
    c.Error_Code__c = code;
    c.Error_Message__c =
      'Document processing stopped: ' +
      code +
      '. See connector runbook.';
  }
}
