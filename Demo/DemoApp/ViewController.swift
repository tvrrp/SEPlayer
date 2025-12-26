//
//  ViewController.swift
//  DemoApp
//
//  Created by Damir Yackupov on 09.06.2025.
//

import UIKit
import SwiftUI

final class ViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let rootView = UrlListScreen(hostViewController: self)
        let hosting  = UIHostingController(rootView: rootView)
        
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        hosting.didMove(toParent: self)
    }
}

struct UrlListScreen: View {
    weak var hostViewController: UIViewController?

    @State private var urls: [String] = [
        Bundle.main.url(forResource: "video", withExtension: "mp4")!.absoluteString,
        "https://v.ozone.ru/vod/video-7/01GE7KG4C15DDZTZ065V4WNAXC/asset_3.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_1.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_2.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_3.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_4.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_5.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_6.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_7.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_8.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_9.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_10.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_11.mp4",
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WeAreGoingOnBullrun.mp4",
        "https://html5demos.com/assets/dizzy.mp4",
        "https://streams.videolan.org/streams/mp4/GHOST_IN_THE_SHELL_V5_DOLBY%20-%203.m4v",
        "https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4",
        "https://github.com/chthomos/video-media-samples/raw/refs/heads/master/big-buck-bunny-1080p-60fps-30sec.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-1/mp4/frame-counter-one-hour.mp4",
//        "https://storage.googleapis.com/media-session/bear-opus.mp4",
        "https://download.dolby.com/us/en/test-tones/dolby-atmos-trailer_amaze_1080.mp4",
    ]
    @State private var newUrl: String = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                

                HStack {
                    TextField("Enter URL", text: $newUrl)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    Button {
                        addUrl()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(newUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                List {
                    ForEach(urls, id: \.self) { url in
                        Text(url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .onTapGesture {
                                openPlayer(urls: [url])
                            }
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
                }
                .listStyle(.plain)

                HStack {
                    Button("Play") {
                        openPlayer(urls: urls)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()

                    Button("Play Simlt") {
                        openSiml()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
            .navigationTitle("Links")
            .toolbar { EditButton() }
        }
    }

    private func addUrl() {
        let trimmed = newUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        urls.append(trimmed)
        newUrl = ""
    }
    
    private func delete(at offsets: IndexSet) {
        urls.remove(atOffsets: offsets)
    }
    
    private func move(from source: IndexSet, to destination: Int) {
        urls.move(fromOffsets: source, toOffset: destination)
    }

    private func openPlayer(urls: [String]) {
        guard
            let host = hostViewController,
            let nav = host.navigationController
        else { return }
        
        let sb = UIStoryboard(name: "Main", bundle: .main)
        guard
            let vc = sb.instantiateViewController(withIdentifier: "PlayerViewController")
                as? PlayerViewController
        else { return }

        vc.videoUrls = urls.compactMap(URL.init(string:))
        vc.repeatMode = urls.count == 1 ? .one : .off
        nav.pushViewController(vc, animated: true)
    }

    private func openSiml() {
        guard
            let host = hostViewController,
            let nav = host.navigationController
        else { return }

//        let viewController = PlayerViewControllerSim()
//
//        viewController.repeatMode = .one
//        nav.pushViewController(viewController, animated: true)
        let vc1 = PlayerViewController()
        let vc2 = PlayerViewController()
        let vc3 = PlayerViewController()
        let vc4 = PlayerViewController()

        vc1.repeatMode = .one
        vc2.repeatMode = .one
        vc3.repeatMode = .one
        vc4.repeatMode = .one

        vc1.videoUrls = [URL(string: "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_1.mp4")!]
        vc2.videoUrls = [URL(string: "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_2.mp4")!]
        vc3.videoUrls = [URL(string: "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_3.mp4")!]
        vc4.videoUrls = [URL(string: "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_4.mp4")!]

        let container = ContnainerVC(vcs: [vc1, vc2, vc3, vc4])
        nav.pushViewController(container, animated: true)
    }
}

private final class ContnainerVC: UIViewController {
    private let vcs: [UIViewController]

    init(vcs: [UIViewController]) {
        self.vcs = vcs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        vcs.forEach {
            view.addSubview($0.view)
            $0.didMove(toParent: self)
        }
    }

    override func viewDidLayoutSubviews() {
        let width = view.bounds.width / 2
        let height = view.bounds.height / 2
        vcs[0].view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        vcs[1].view.frame = CGRect(x: width, y: 0, width: width, height: height)
        vcs[2].view.frame = CGRect(x: 0, y: height, width: width, height: height)
        vcs[3].view.frame = CGRect(x: width, y: height, width: width, height: height)
    }
}
