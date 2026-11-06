import { Controller } from "@hotwired/stimulus";

export default class AttachmentUploadController extends Controller {
  static targets = ["fileInput", "submitButton", "fileName", "uploadText"];
  static values = {
    maxFiles: Number,
    maxSize: Number,
  };

  connect() {
    this.updateSubmitButton();
  }

  triggerFileInput() {
    this.fileInputTarget.click();
  }

  updateSubmitButton() {
    const files = Array.from(this.fileInputTarget.files);
    const hasFiles = files.length > 0;

    // Basic validation hints (server validates definitively)
    let isValid = hasFiles;
    let errorMessage = "";

    if (hasFiles) {
      if (this.hasUploadTextTarget)
        this.uploadTextTarget.classList.add("hidden");
      if (this.hasFileNameTarget) {
        const filenames = files.map((f) => f.name).join(", ");
        const textElement = this.fileNameTarget.querySelector("p");
        if (textElement) textElement.textContent = filenames;
        this.fileNameTarget.classList.remove("hidden");
      }

      // Check file count
      if (files.length > this.maxFilesValue) {
        isValid = false;
        errorMessage = this.message("tooManyMessage", this.maxFilesValue);
      }

      // Check file sizes
      const oversizedFiles = files.filter(
        (file) => file.size > this.maxSizeValue,
      );
      if (oversizedFiles.length > 0) {
        isValid = false;
        errorMessage = this.message(
          "tooLargeMessage",
          Math.round(this.maxSizeValue / 1024 / 1024),
        );
      }
    } else {
      if (this.hasUploadTextTarget)
        this.uploadTextTarget.classList.remove("hidden");
      if (this.hasFileNameTarget) this.fileNameTarget.classList.add("hidden");
    }

    // Inside another form (new transaction) its own submit button stays as is:
    // an invalid selection blocks that form's submit and the dropzone says why.
    if (!this.hasSubmitButtonTarget) {
      this.fileInputTarget.setCustomValidity(errorMessage);
      const textElement =
        this.hasFileNameTarget && this.fileNameTarget.querySelector("p");
      if (errorMessage && textElement) textElement.textContent = errorMessage;
      // The message is not visible while the section holding the dropzone is collapsed.
      if (errorMessage)
        this.element.closest("details")?.setAttribute("open", "");
      return;
    }

    this.submitButtonTarget.disabled = !isValid;

    if (hasFiles && isValid) {
      const count = files.length;
      this.submitButtonTarget.textContent =
        count === 1 ? "Upload 1 file" : `Upload ${count} files`;
    } else if (errorMessage) {
      this.submitButtonTarget.textContent = errorMessage;
    } else {
      this.submitButtonTarget.textContent = "Upload";
    }
  }

  message(key, max) {
    const template = this.fileInputTarget.dataset[key] || "";
    return template.replace("%{max}", max);
  }
}
