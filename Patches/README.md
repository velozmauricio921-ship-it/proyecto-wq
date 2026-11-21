# WQ Files .3105 Package Library

This module provides the local `.3105` package library, import and decoding, workspace browsing, and project editing. It does not apply package contents to target applications.

`PatchProjectLibrary` stores packages under `Application Support/WQFiles/PatchProjects`; valid legacy packages are copied only when the destination name is unused, and their source files are retained. `PatchWorkspaceService` stores editable workspaces under `Application Support/WQFiles/Patches` and migrates valid legacy workspaces without replacing existing destinations.

`PatchProjectsView`, `PatchProjectEditorView`, and `FolderPatchSelectionView` provide the library, import, editor, and folder capture UI. `WQPatchIntegrationSupport.swift` hosts these views in UIKit. `main.m` opens the library from Vault > Patches and continues routing `.3105` documents to the unchanged `WQPatchReader`.

`build.sh` compiles the Swift sources as the `WQPatchIntegration` module, emits `WQPatchIntegration-Swift.h`, compiles the Objective-C application with that header, and links SwiftUI, CryptoKit, Combine, Security, and UniformTypeIdentifiers. The arm64 and iOS 26.0 build policy is unchanged; building the iOS app requires Apple's Xcode toolchain.