import AppKit
import SwiftUI
import XCTest
import CoreModel
import Surfaces
@testable import AppShell

@MainActor
final class BotAvatarAppearanceTests: XCTestCase {
    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["RC_AVATAR_ARTIFACT_DIR"] else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    func test_sharedAvatarRendersTheChosenColorAtEverySurfaceSize() throws {
        let spec = BotBlobatarSpec(shape: .cloud, hue: .named("cyan"), frozenSeed: "Developer")
        let hosting = NSHostingView(rootView:
            HStack(alignment: .center, spacing: 16) {
                ForEach([16, 20, 36, 188], id: \.self) { size in
                    BotsAvatarView(name: "Developer", handle: "elephant-developer", symbol: spec.token,
                                   size: CGFloat(size), attention: .needsAttention)
                }
            }
            .padding(24)
            .background(Color.black)
            .overlay(alignment: .topLeading) {
                Color(red: 34.0 / 255, green: 211.0 / 255, blue: 238.0 / 255)
                    .frame(width: 12, height: 12)
            }
        )
        hosting.setFrameSize(NSSize(width: 420, height: 240))
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        settle(hosting)
        try capture(hosting, name: "shared-avatar-sizes")
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let reference = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(reference.greenComponent, reference.redComponent)
        var coloredColumns = Set<Int>()
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(color.redComponent - reference.redComponent) < 0.01 &&
                    abs(color.greenComponent - reference.greenComponent) < 0.01 &&
                    abs(color.blueComponent - reference.blueComponent) < 0.01 {
                    coloredColumns.insert(x)
                    break
                }
            }
        }
        let segments = coloredColumns.filter { !coloredColumns.contains($0 - 1) }
        XCTAssertEqual(segments.count, 5, "four avatars must match the rendered swatch, including Needs you")
    }

    func test_studioSaveReopenAndSchedulesKeepTheSameAvatar() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-studio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory.path)
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Developer", title: "Senior Full-Stack TypeScript Engineer (Backend + React)",
                                handle: "elephant-developer")
        vm.openStudio(bot)
        vm.studioDraft.avatarSymbol = BotBlobatarSpec.default.selecting(
            shape: .cloud, hue: .named("cyan"), name: "Developer", handle: bot.handle
        ).token
        let expected = vm.studioDraft.avatarSymbol
        let saved = try vm.saveStudio()
        XCTAssertEqual(saved.avatarSymbol, expected)
        vm.openStudio(try XCTUnwrap(context.botStore.get(id: saved.id)))
        XCTAssertEqual(vm.studioDraft.avatarSymbol, expected)
        vm.routineName = "Daily code review"
        vm.routinePrompt = "Review the current changes"
        vm.saveRoutine()
        vm.reloadScheduleTasks()
        XCTAssertEqual(vm.scheduleTaskItems.first?.botAvatarSymbol, expected)
        let restored = BotsViewModel(context: context)
        restored.openStudio(try XCTUnwrap(context.botStore.get(id: saved.id)))
        XCTAssertEqual(restored.studioDraft.avatarSymbol, expected)
        let hosting = NSHostingView(rootView: BotsRootView(vm: restored).frame(width: 1200, height: 900))
        hosting.setFrameSize(NSSize(width: 1200, height: 900))
        hosting.wantsLayer = true
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        window.orderBack(nil)
        settle(hosting)
        try capture(hosting, name: "studio-saved")
        for width in [220.0, 280.0] {
            let picker = NSHostingView(rootView: BotBlobatarEditor(
                token: .constant(expected), seed: "Developer", handle: saved.handle
            ).frame(width: width))
            picker.setFrameSize(NSSize(width: width, height: 900))
            picker.wantsLayer = true
            let pickerWindow = NSWindow(contentRect: picker.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            pickerWindow.isReleasedWhenClosed = false
            pickerWindow.appearance = NSAppearance(named: .darkAqua)
            pickerWindow.contentView = picker
            defer { pickerWindow.contentView = nil; pickerWindow.close() }
            settle(picker)
            XCTAssertLessThanOrEqual(picker.fittingSize.width, width)
            XCTAssertLessThanOrEqual(picker.fittingSize.height, 900)
            try capture(picker, name: "picker-\(Int(width))")
        }
    }
}
