import { LightningElement, api } from "lwc";
import { statusInfo } from "c/sfdcDcxJobState";

export default class SfdcDcxStatusBadge extends LightningElement {
  @api status;

  get info() {
    return statusInfo(this.status);
  }

  get iconVariant() {
    const tone = this.info.tone;
    return tone === "success" || tone === "error" ? "inverse" : null;
  }
}
