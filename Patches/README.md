# WQ Files Patches Integration

This module adapts the 3105 patch library and editor to the UIKit application.
The original implementation and guide remain in `3105-1.1.1/3105-1.1.1/`.

## Source mapping

- `helpers/PatchProjectModels.swift`, `PatchPackageCodec.swift`, `PatchKeyStore.swift`, `PatchDraftService.swift`, `PatchDraftCoordinator.swift`, and `PatchTransaction.swift` retain the original package, validation, draft, key, and transaction logic.
- `helpers/PatchProjectLibrary.swift` stores packages under `Application Support/WQFiles/PatchProjects`. Legacy packages are validated and copied only when the destination name is unused. Sources are retained.
- `helpers/PatchWorkspaceService.swift` stores editable workspaces under `Application Support/WQFiles/Patches`. Valid legacy workspaces are copied without replacing existing destinations or removing their sources.
- `views/PatchProjectsView.swift`, `PatchProjectEditorView.swift`, and `FolderPatchSelectionView.swift` retain the 3105 library, editor, and selection UI.
- `helpers/AuthorizedPatchService.swift` prepares, validates, previews, applies, and restores operations through the original transaction journal.
- `WQPatchIntegrationSupport.swift` supplies the SwiftUI/UIKit host, folder picker, confirmation flow, and minimal 3105 presentation dependencies.
- `main.m` opens the host from Vault > Patches and routes workspace browsing through WQ Files. `WQPatchReader.m` remains unchanged and continues to read `.3105` files.

## Authorization boundary

Each target identifier must be mapped to a folder chosen with the iOS document picker. Apply displays the resolved create/replace operations and requires a separate confirmation. Targets are revalidated before writing, symbolic-link paths are rejected, and the original transaction code keeps backups, verifies replacement digests, rolls back failed writes, and restores only matching targets. Application data-container and installed application-bundle roots are rejected.

`DevicePatchService.swift` and `ContainerStore.swift` are intentionally not compiled into this module. The former delegates target resolution to the latter, whose fallback can depend on privileged sandbox access. WQ's file/container browser is not used as an implicit patch authorization source.

## Dependencies not integrated

- `KeyAuthLicenseService.swift`, `LicenseGateStore.swift`, and other 3105 authentication code are excluded. WQ's KeyAuth configuration and integration are unchanged.
- `PackageRepositoryStore.swift` and remote repository UI are excluded; the local `.3105` document picker remains available.
- `SecureZIPArchive.swift` and the `Preloaded.tendies` archive path are excluded. WQ's build already copies the `Preloaded/` resource directory, which the library installs incrementally without replacing cached packages.
- `Utils.swift` is excluded; module diagnostics use `print` rather than 3105's private logger.

## Build integration

`build.sh` compiles the Swift sources as the `WQPatchIntegration` module, emits `WQPatchIntegration-Swift.h`, compiles the Objective-C application with that header, and links the objects with SwiftUI, CryptoKit, Combine, Security, and UniformTypeIdentifiers. The existing arm64 and iOS 26.0 build policy is unchanged. The iOS build must be run with Apple's Xcode toolchain.