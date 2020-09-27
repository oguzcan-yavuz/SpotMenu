//
//  AppDelegate.swift
//  SpotMenu
//
//  Created by Miklós Kristyán on 02/09/16.
//  Copyright © 2016 KM. All rights reserved.
//

import AppKit.NSAppearance
import Carbon.HIToolbox
import Cocoa
import MusicPlayer
import Sparkle
import Fabric
import Crashlytics

@NSApplicationMain
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Constants {
        static let statusItemIconLength: CGFloat = 30
        static let statusItemLength: CGFloat = 250
    }

    // MARK: - Properties
    private var hudController: HudWindowController?
    private var preferencesController: NSWindowController?
    private var hiddenController: NSWindowController?
    
    private var spotifyAccessToken: String?
    private var spotifyClientId = "42047dfe5c2349bea08a6e5916105fd8"
    private var spotifySecretKey = "4ddb9b926ae146e58302a9bd0b2dda07"

    // private let popoverDelegate = PopOverDelegate()

    private var eventMonitor: EventMonitor?
    private let issuesURL = URL(string: "https://github.com/kmikiy/SpotMenu/issues")
    private let kmikiyURL = URL(string: "https://github.com/kmikiy")
    private let menu = StatusMenu().menu
    private let spotMenuIcon = NSImage(named: NSImage.Name(rawValue: "StatusBarButtonImage"))
    private let spotMenuIconItunes = NSImage(named: NSImage.Name(rawValue: "StatusBarButtonImageItunes"))
    private var lastStatusTitle: String = ""
    private var removeHudTimer: Timer?
    private var musicPlayerManager: MusicPlayerManager!

    private lazy var statusItem: NSStatusItem = {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.length = Constants.statusItemIconLength
        return statusItem
    }()

    private lazy var contentView: NSView? = {
        let view = (statusItem.value(forKey: "window") as? NSWindow)?.contentView
        return view
    }()

    private lazy var scrollingStatusItemView: ScrollingStatusItemView = {
        let view = ScrollingStatusItemView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.icon = chooseIcon(musicPlayerName: MusicPlayerName(rawValue: UserPreferences.lastMusicPlayer)!)
        view.lengthHandler = handleLength
        return view
    }()

    private lazy var handleLength: StatusItemLengthUpdate = { length in
        if length < Constants.statusItemLength {
            self.statusItem.length = length
        } else {
            self.statusItem.length = Constants.statusItemLength
        }
    }

    // MARK: - AppDelegate methods

    func applicationDidFinishLaunching(_: Notification) {
        // Fabric.with([Crashlytics.self])
        
        UserPreferences.initializeUserPreferences()

        musicPlayerManager = MusicPlayerManager()
        musicPlayerManager.add(musicPlayer: .spotify)
        musicPlayerManager.add(musicPlayer: .iTunes)

        musicPlayerManager.delegate = self
        let lastMusicPlayerName = MusicPlayerName(rawValue: UserPreferences.lastMusicPlayer)!
        let lastMusicPlayer = musicPlayerManager.existMusicPlayer(with: lastMusicPlayerName)
        musicPlayerManager.currentPlayer = lastMusicPlayer

        let popoverVC = PopOverViewController(nibName: NSNib.Name(rawValue: "PopOver"), bundle: nil)
        popoverVC.setUpMusicPlayerManager()

        hiddenController = (NSStoryboard(name: NSStoryboard.Name(rawValue: "Hidden"), bundle: nil).instantiateInitialController() as! NSWindowController)
        hiddenController?.contentViewController = popoverVC
        hiddenController?.window?.isOpaque = false
        hiddenController?.window?.backgroundColor = .clear
        hiddenController?.window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        //hiddenController?.window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        //hiddenController?.window?.ignoresMouseEvents = true

        loadSubviews()
        updateTitle()

        eventMonitor = EventMonitor(mask: [NSEvent.EventTypeMask.leftMouseDown, NSEvent.EventTypeMask.rightMouseDown]) { [unowned self] event in
            self.closePopover(event)
        }

        if UserPreferences.keyboardShortcutEnabled {
            registerHotkey()
        }
    }

    func applicationWillTerminate(_: Notification) {
        // Insert code here to tear down your application
        eventMonitor?.stop()
    }

    // MARK: - Public methods

    func registerHotkey() {
        guard let hotkeyCenter = DDHotKeyCenter.shared() else { return }

        let modifiers: UInt = NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.shift.rawValue

        // Register system-wide summon hotkey
        hotkeyCenter.registerHotKey(withKeyCode: UInt16(kVK_ANSI_M),
                                    modifierFlags: modifiers,
                                    target: self,
                                    action: #selector(AppDelegate.hotkeyAction),
                                    object: nil)

        hotkeyCenter.registerHotKey(withKeyCode: UInt16(kVK_LeftArrow),
                                    modifierFlags: modifiers,
                                    target: self,
                                    action: #selector(AppDelegate.hotkeyActionLeft),
                                    object: nil)

        hotkeyCenter.registerHotKey(withKeyCode: UInt16(kVK_RightArrow),
                                    modifierFlags: modifiers,
                                    target: self,
                                    action: #selector(AppDelegate.hotkeyActionRight),
                                    object: nil)

        hotkeyCenter.registerHotKey(withKeyCode: UInt16(kVK_Space),
                                    modifierFlags: modifiers,
                                    target: self,
                                    action: #selector(AppDelegate.hotkeyActionSpace),
                                    object: nil)
    }

    func unregisterHotKey() {
        guard let hotkeyCenter = DDHotKeyCenter.shared() else { return }
        hotkeyCenter.unregisterAllHotKeys()
    }

    @objc func hotkeyActionSpace() {
        if (musicPlayerManager.currentPlayer?.playbackState == .paused){
            musicPlayerManager.currentPlayer?.play()
        } else {
            musicPlayerManager.currentPlayer?.stop()
        }
    }

    @objc func hotkeyActionRight() {
        musicPlayerManager.currentPlayer?.playNext()
    }

    @objc func hotkeyActionLeft() {
        musicPlayerManager.currentPlayer?.playPrevious()
    }
    
    struct SpotifyAuthResponse: Codable {
        let access_token: String
        let token_type: String
        let expires_in: Int
    }
    
    struct AudioFeatures: Codable {
        let key: Int
        let mode: Int
        let time_signature: Int
        let tempo: Float
    }
    
    func getSpotifyAccessToken(completion: @escaping () -> ()) {
        let url = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let authorization = "\(spotifyClientId):\(spotifySecretKey)".data(using: .utf8)?.base64EncodedString()
        request.setValue("Basic \(authorization ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyParams = "grant_type=client_credentials"
        request.httpBody = bodyParams.data(using: String.Encoding.ascii, allowLossyConversion: true)
        
        let task = URLSession.shared.dataTask(with: request) {(data, response, error) in
            if let data = data {
                do {
                    let res = try JSONDecoder().decode(SpotifyAuthResponse.self, from: data)
                    self.spotifyAccessToken = res.access_token
                    completion();
                } catch let (error) {
                    print(error)
                }
            }
        }
        
        task.resume();
    }
    
    func getAudioFeatures(id: String?, completion: @escaping (AudioFeatures?) -> (), retry: Int = 1) {
        if id == nil {
            completion(nil)
        } else {
            let trackId = id!.components(separatedBy: ":").last
            let url = URL(string: "https://api.spotify.com/v1/audio-features/\(trackId ?? "")")!
            var request = URLRequest(url: url)
            if spotifyAccessToken != nil {
                request.setValue("Bearer \(spotifyAccessToken ?? "")", forHTTPHeaderField: "Authorization")
            }
    
            let task = URLSession.shared.dataTask(with: request) {(data, response, error) in
                if let httpResponse = response as? HTTPURLResponse {
                                if httpResponse.statusCode == 401 && retry > 0 {
                                    print("Refreshing spotify token...")
                                    return self.getSpotifyAccessToken() { () -> () in
                                        return self.getAudioFeatures(id: id, completion: completion, retry: retry - 1);
                                    };
                                }
                            }
                if let data = data {
                    do {
                        let audioFeatures = try JSONDecoder().decode(AudioFeatures.self, from: data)
                        print("Audio features: \(audioFeatures)")
                        completion(audioFeatures)
                    } catch let error {
                        print(error)
                    }
                }
            }
            
            task.resume()
        }
    }

    @objc func hotkeyAction() {
        let sb = NSStoryboard(name: NSStoryboard.Name(rawValue: "Hud"), bundle: nil)
        hudController = sb.instantiateInitialController() as? HudWindowController
                        
        getAudioFeatures(id: musicPlayerManager.currentPlayer?.currentTrack?.id) { (audioFeatures) -> () in
            self.hudController!.setText(text: StatusItemBuilder(
                title: self.musicPlayerManager.currentPlayer?.currentTrack?.title,
                artist: self.musicPlayerManager.currentPlayer?.currentTrack?.artist,
                albumName: self.musicPlayerManager.currentPlayer?.currentTrack?.album,
                isPlaying: self.musicPlayerManager.currentPlayer?.playbackState == MusicPlaybackState.playing,
                key: audioFeatures?.key,
                tempo: audioFeatures?.tempo,
                timeSignature: audioFeatures?.time_signature,
                mode: audioFeatures?.mode)
                .hideWhenPaused(v: false)
                .showTitle(v: true)
                .showAlbumName(v: true)
                .showArtist(v: true)
                .showPlayingIcon(v: true)
                .getString())

            self.hudController?.showWindow(nil)
            self.hudController?.window?.makeKeyAndOrderFront(self)
            NSApp.activate(ignoringOtherApps: true)
            if let t = self.removeHudTimer {
                t.invalidate()
            }
            self.removeHudTimer = Timer.scheduledTimer(
                timeInterval: 4,
                target: self,
                selector: #selector(AppDelegate.removeHud),
                userInfo: nil,
                repeats: false)

        }
    }

    @objc func removeHud() {
        hudController = nil
    }

    @objc func updateTitle() {
        getAudioFeatures(id: musicPlayerManager.currentPlayer?.currentTrack?.id) { (audioFeatures) -> () in
            let statusItemTitle = StatusItemBuilder(
                title: self.musicPlayerManager.currentPlayer?.currentTrack?.title,
                artist: self.musicPlayerManager.currentPlayer?.currentTrack?.artist,
                albumName: self.musicPlayerManager.currentPlayer?.currentTrack?.album,
                isPlaying: self.musicPlayerManager.currentPlayer?.playbackState == MusicPlaybackState.playing,
                key: audioFeatures?.key,
                tempo: audioFeatures?.tempo,
                timeSignature: audioFeatures?.time_signature,
                mode: audioFeatures?.mode)
                .hideWhenPaused(v: UserPreferences.hideTitleArtistWhenPaused)
                .showTitle(v: UserPreferences.showTitle)
                .showAlbumName(v: UserPreferences.showAlbumName)
                .showArtist(v: UserPreferences.showArtist)
                .showPlayingIcon(v: UserPreferences.showPlayingIcon)
                .getString()
            if self.lastStatusTitle != statusItemTitle {
                self.updateTitle(newTitle: statusItemTitle)
            }
        }
    }

    // MARK: - Popover methods

    @objc func openPrefs(_: NSMenuItem) {
        preferencesController = (NSStoryboard(name: NSStoryboard.Name(rawValue: "Preferences"), bundle: nil).instantiateInitialController() as! NSWindowController)
        preferencesController?.showWindow(self)
    }

    func openURL(url: URL?) {
        if let url = url, NSWorkspace.shared.open(url) {
            print("default browser was successfully opened")
        }
    }

    @objc func openKmikiy(_: NSMenuItem) {
        openURL(url: kmikiyURL)
    }

    @objc func openIssues(_: NSMenuItem) {
        openURL(url: issuesURL)
    }

    @objc func quit(_: NSMenuItem) {
        NSApp.terminate(self)
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        let event = NSApp.currentEvent!

        switch (event.type, event.modifierFlags.contains(.control)) {
        case (NSEvent.EventType.rightMouseUp, _),
             (NSEvent.EventType.leftMouseUp, true)   :
            if hiddenController?.window?.isVisible ?? true {
                closePopover(sender)
            }
            statusItem.menu = menu
            statusItem.popUpMenu(menu)

            // This is critical, otherwise clicks won't be processed again
            statusItem.menu = nil
        default:
            if hiddenController?.window?.isVisible ?? true {
                closePopover(sender)
            } else {
                // SpotifyAppleScript.startSpotify(hidden: true)
                showPopover(sender)
            }
        }
    }

    @objc func checkForUpdates(_: NSMenuItem) {
        SUUpdater.shared().checkForUpdates(nil)
    }

    // MARK: - Private methods

    private func loadSubviews() {
        guard let contentView = contentView else { return }

        if let button = statusItem.button {
            button.sendAction(on: [NSEvent.EventTypeMask.leftMouseUp, NSEvent.EventTypeMask.rightMouseUp])
            button.action = #selector(AppDelegate.togglePopover(_:))
        }

        contentView.addSubview(scrollingStatusItemView)

        NSLayoutConstraint.activate([
            scrollingStatusItemView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollingStatusItemView.leftAnchor.constraint(equalTo: contentView.leftAnchor),
            scrollingStatusItemView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollingStatusItemView.rightAnchor.constraint(equalTo: contentView.rightAnchor)])
    }

    private func updateTitle(newTitle: String) {
        scrollingStatusItemView.icon = chooseIcon(musicPlayerName: musicPlayerManager.currentPlayer?.name)
        scrollingStatusItemView.text = newTitle

        lastStatusTitle = newTitle

        if newTitle.count == 0 && statusItem.button != nil {
            statusItem.length = scrollingStatusItemView.hasImage ? Constants.statusItemIconLength : 0
        }
    }

    private func chooseIcon(musicPlayerName: MusicPlayerName?) -> NSImage! {
        if !UserPreferences.showSpotMenuIcon {
            return nil
        }
        
        if musicPlayerName == MusicPlayerName.iTunes {
            return spotMenuIconItunes
        } else {
            return spotMenuIcon
        }
    }

    private func showPopover(_: AnyObject?) {

        let rect = statusItem.button?.window?.convertToScreen((statusItem.button?.frame)!)
        let menubarHeight = rect?.height ?? 22
        let height = hiddenController?.window?.frame.height ?? 300
        let xOffset = UserPreferences.fixPopoverToTheRight ? ((hiddenController?.window?.contentView?.frame.minX)! - (statusItem.button?.frame.minX)!) : ((hiddenController?.window?.contentView?.frame.midX)! - (statusItem.button?.frame.midX)!)
        let x = (rect?.origin.x)! - xOffset
        let y = (rect?.origin.y)! // - (hiddenController?.contentViewController?.view.frame.maxY)!
        hiddenController?.window?.setFrameOrigin(NSPoint(x: x, y: y-height+menubarHeight))
        hiddenController?.showWindow(self)
        eventMonitor?.start()
    }

    private func closePopover(_ sender: AnyObject?) {
        hiddenController?.close()
        eventMonitor?.stop()
    }

}

extension AppDelegate: MusicPlayerManagerDelegate {
    func manager(_: MusicPlayerManager, trackingPlayer _: MusicPlayer, didChangeTrack _: MusicTrack, atPosition _: TimeInterval) {
        updateTitle()
    }

    func manager(_: MusicPlayerManager, trackingPlayer _: MusicPlayer, playbackStateChanged _: MusicPlaybackState, atPosition _: TimeInterval) {
        updateTitle()
    }

    func manager(_: MusicPlayerManager, trackingPlayerDidQuit _: MusicPlayer) {
        updateTitle()
    }

    func manager(_: MusicPlayerManager, trackingPlayerDidChange player: MusicPlayer) {
        UserPreferences.lastMusicPlayer = player.name.rawValue
    }
}
