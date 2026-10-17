import Foundation

// Codes and catalog entries for the "Creating VMs" area. See PommeErrorCatalog.swift.

extension PommeErrorCode {
    static let provisioningPhaseFailed: Self = "provisioning-phase-failed"
    static let provisioningPhaseInterrupted: Self = "provisioning-phase-interrupted"
    static let provisioningPlanInvalid: Self = "provisioning-plan-invalid"
    static let provisioningOwnershipMismatch: Self = "provisioning-ownership-mismatch"
    static let provisioningAgentInvalid: Self = "provisioning-agent-invalid"
    static let provisioningJournalInvalid: Self = "provisioning-journal-invalid"
    static let provisioningJournalIntegrityFailed: Self = "provisioning-journal-integrity-failed"
    static let provisioningJournalStale: Self = "provisioning-journal-stale"
    static let provisioningJournalUnsafe: Self = "provisioning-journal-unsafe"
    static let provisioningNothingToRepair: Self = "provisioning-nothing-to-repair"
    static let provisioningRepairUnavailable: Self = "provisioning-repair-unavailable"
    static let provisioningIntegrationUnavailable: Self = "provisioning-integration-unavailable"
    static let provisioningDispatchFailed: Self = "provisioning-dispatch-failed"
    static let sshBootstrapInvalid: Self = "ssh-bootstrap-invalid"
    static let sshBootstrapFailed: Self = "ssh-bootstrap-failed"
    static let sshBootstrapTimedOut: Self = "ssh-bootstrap-timed-out"
    static let templateNotFound: Self = "template-not-found"
    static let templateExists: Self = "template-exists"
    static let templateManifestInvalid: Self = "template-manifest-invalid"
    static let templateIncomplete: Self = "template-incomplete"
    static let templateDiskSizeMismatch: Self = "template-disk-size-mismatch"
    static let templateCloneFailed: Self = "template-clone-failed"
}

extension PommeErrorCatalog {
    static let provisioning: [Entry] = [
        .init(.provisioningPhaseFailed, area: "Creating VMs",
              title: "A step of VM creation failed.",
              cause: "Creation is a journaled workflow. A step, such as installing macOS or the Pomme agent, failed after it started. Pomme kept the VM and its journal so that you can resume. The error's causes give the step's reason, such as a full disk.",
              resolution: [
                  "Read the reason in the message and correct it.",
                  "Run `pomme create NAME --resume` to continue from the first unfinished step.",
                  "To start over instead, run `pomme delete NAME`, then create the VM again."
              ],
              hint: "Correct the cause, then run `pomme create NAME --resume` to continue."),
        .init(.provisioningPhaseInterrupted, area: "Creating VMs",
              title: "A step of VM creation was interrupted.",
              cause: "A creation step started but didn't record a result, and repeating it isn't safe. For example, repeating the first boot could create a second owner account.",
              resolution: [
                  "Run `pomme agent status NAME` to see the VM's workflow.",
                  "Delete the VM with `pomme delete NAME`, then create it again."
              ]),
        .init(.provisioningPlanInvalid, area: "Creating VMs",
              title: "The VM's provisioning plan isn't valid.",
              cause: "The plan that records how Pomme creates the VM is missing a value, or it's a plan that this version of Pomme doesn't accept.",
              resolution: [
                  "If a newer version of Pomme created the VM, update Pomme with `pomme update`.",
                  "Otherwise, delete the VM with `pomme delete NAME`, then create it again."
              ]),
        .init(.provisioningOwnershipMismatch, area: "Creating VMs",
              title: "The VM doesn't match its provisioning records.",
              cause: "Pomme acts only on the exact VM that it created. The VM bundle's identity, location, or name doesn't match the records that Pomme kept, usually because the bundle was moved, copied, or replaced.",
              resolution: [
                  "Run `pomme list` to check the VM.",
                  "Move the bundle back if you moved it.",
                  "Otherwise, delete the VM with `pomme delete NAME --force`, then create it again. Because Pomme can't prove which VM the bundle is, it removes only the bundle and keeps the VM's Keychain items."
              ]),
        .init(.provisioningAgentInvalid, area: "Creating VMs",
              title: "The VM's Pomme agent identity isn't valid.",
              cause: "The provisioning plan names a Pomme agent whose role, digest, or protocol version isn't valid.",
              resolution: ["Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.provisioningJournalInvalid, area: "Creating VMs",
              title: "The VM's provisioning journal isn't valid.",
              cause: "The journal that records each creation step has a missing value, an unknown schema, or steps in an order that isn't valid.",
              resolution: [
                  "Delete the VM with `pomme delete NAME --force`, then create it again. Pomme removes only the bundle and keeps the VM's Keychain items.",
                  "If the journal wasn't edited, run `pomme bug-report NAME` and attach the file to a new issue."
              ]),
        .init(.provisioningJournalIntegrityFailed, area: "Creating VMs",
              title: "Pomme couldn't verify the VM's provisioning records.",
              cause: "Pomme signs the VM's provisioning journal with a key in your login Keychain. The signature doesn't match, the key isn't available, or a record was changed outside Pomme.",
              resolution: [
                  "Unlock your login Keychain, then retry.",
                  "If the failure continues, delete the VM with `pomme delete NAME --force`, then create it again. Pomme removes only the bundle and keeps the VM's Keychain items."
              ]),
        .init(.provisioningJournalStale, area: "Creating VMs",
              title: "The VM's provisioning journal is out of date.",
              cause: "The journal is older than the last generation that Pomme recorded, or another process changed it at the same time.",
              resolution: [
                  "Make sure that no other Pomme command is using the VM, then retry.",
                  "If the journal was restored from a backup, delete the VM with `pomme delete NAME` and create it again."
              ]),
        .init(.provisioningJournalUnsafe, area: "Creating VMs",
              title: "Pomme couldn't access the VM's provisioning journal safely.",
              cause: "The journal file or its directory is missing, is a symbolic link, is readable by other users, or couldn't be written.",
              resolution: [
                  "Run Pomme as the user who created the VM, not with `sudo`.",
                  "Check the permissions of the VM bundle with `pomme inspect NAME`."
              ]),
        .init(.provisioningNothingToRepair, area: "Creating VMs",
              title: "The VM's agent doesn't need repair.",
              cause: "Agent provisioning is complete. `pomme agent repair` doesn't reconcile SIP or AMFI security transactions.",
              resolution: ["Run `pomme agent status NAME` to check the agent."]),
        .init(.provisioningRepairUnavailable, area: "Creating VMs",
              title: "Agent repair can't continue VM creation.",
              cause: "The VM's creation stopped at a step that `pomme agent repair` doesn't handle.",
              resolution: ["Run `pomme create NAME --resume` to continue creation."],
              hint: "Run `pomme create NAME --resume` to continue."),
        .init(.provisioningIntegrationUnavailable, area: "Creating VMs",
              title: "A component that the operation needs isn't available.",
              cause: "The operation needs an internal component, such as an authenticated Recovery session or a verified installation receipt, that isn't available. This is a bug in Pomme.",
              resolution: ["Update Pomme with `pomme update`.", "If the failure continues, run `pomme bug-report` and attach the file to a new issue."],
              reportable: true),
        .init(.provisioningDispatchFailed, area: "Creating VMs",
              title: "Pomme couldn't set up the macOS owner account for the first boot.",
              cause: "Virtualization.framework rejected the guest provisioning options, or Pomme couldn't record that it started them. Pomme shows only the error's code, because the options include the owner account's credentials.",
              resolution: ["Run `pomme create NAME --resume` to retry.", "If it fails again, run `pomme bug-report NAME` and attach the file to a new issue."]),
        .init(.sshBootstrapInvalid, area: "Creating VMs",
              title: "Pomme couldn't verify the guest bootstrap.",
              cause: "While it installs the Pomme agent over SSH, Pomme checks the guest's network lease, host key, and staged files. One of them was missing, ambiguous, or didn't match.",
              resolution: ["Run `pomme create NAME --resume` to retry.", "If it fails again, run `pomme bug-report NAME` and attach the file to a new issue."]),
        .init(.sshBootstrapFailed, area: "Creating VMs",
              title: "The guest bootstrap command failed.",
              cause: "A command that Pomme runs to install the Pomme agent over SSH couldn't start or exited with an error.",
              resolution: ["Run `pomme create NAME --resume` to retry.", "Run `pomme log NAME --last 5m` to see the guest's log."]),
        .init(.sshBootstrapTimedOut, area: "Creating VMs",
              title: "The guest bootstrap command timed out.",
              cause: "A command that Pomme runs to install the Pomme agent over SSH didn't finish in time. The guest might still be finishing its first boot.",
              resolution: ["Run `pomme create NAME --resume` to retry."]),
        .init(.templateNotFound, area: "Creating VMs",
              title: "The template doesn't exist.",
              cause: "No installed template has the name that you gave.",
              resolution: ["Run `pomme template list` to see your templates.", "Create the template with `pomme template create NAME --latest`."]),
        .init(.templateExists, area: "Creating VMs",
              title: "A template with that name already exists.",
              cause: "Pomme doesn't replace an installed template.",
              resolution: ["Choose another name, or delete the template with `pomme template delete NAME`, then retry."]),
        .init(.templateManifestInvalid, area: "Creating VMs",
              title: "The template's manifest isn't valid.",
              cause: "The template's `Template.json` file is missing, can't be read, or has a value that isn't valid.",
              resolution: ["Delete the template with `pomme template delete NAME`, then create it again with `pomme template create NAME`."]),
        .init(.templateIncomplete, area: "Creating VMs",
              title: "The template is incomplete.",
              cause: "The template bundle is missing its disk image, auxiliary storage, or hardware model.",
              resolution: ["Delete the template with `pomme template delete NAME`, then create it again with `pomme template create NAME`."]),
        .init(.templateDiskSizeMismatch, area: "Creating VMs",
              title: "The disk size doesn't match the template.",
              cause: "A VM cloned from a template keeps the template's disk size, and `--disk-size` asked for a different size.",
              resolution: ["Omit `--disk-size` to use the template's size.", "To use another size, create a template with that size."]),
        .init(.templateCloneFailed, area: "Creating VMs",
              title: "Cloning the template failed.",
              cause: "Pomme couldn't copy the template's files into the new VM bundle. The error's causes give the reason, such as a full disk.",
              resolution: ["Read the reason in the message and correct it.", "Free space on the volume that holds your VMs if it's full, then retry."])
    ]
}
