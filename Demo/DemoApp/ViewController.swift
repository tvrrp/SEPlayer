//
//  ViewController.swift
//  DemoApp
//
//  Created by Damir Yackupov on 09.06.2025.
//

import UIKit
import SwiftUI
import SEPlayer

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
        "https://streams.videolan.org/streams/mp4/GHOST_IN_THE_SHELL_V5_DOLBY%20-%203.m4v",
        "https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4",
        "https://github.com/chthomos/video-media-samples/raw/refs/heads/master/big-buck-bunny-1080p-60fps-30sec.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-1/mp4/frame-counter-one-hour.mp4",
        "https://download.dolby.com/us/en/test-tones/dolby-atmos-trailer_amaze_1080.mp4",
    ]
    @State private var newUrl: String = ""
    @State private var seekParameters: PlayerSeekParameters = .default

    enum PlayerSeekParameters: String, CaseIterable, Hashable {
        case `default`
        case exact
        case closestSync
        case previousSync
        case nextSync

        var seekParameters: SeekParameters {
            switch self {
            case .default:
                SeekParameters.default
            case .exact:
                SeekParameters.exact
            case .closestSync:
                SeekParameters.closestSync
            case .previousSync:
                SeekParameters.previousSync
            case .nextSync:
                SeekParameters.nextSync
            }
        }
    }
    
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

                Picker("SeekParameters", selection: $seekParameters) {
                    ForEach(PlayerSeekParameters.allCases, id: \.self) {
                        Text($0.rawValue)
                    }
                }
                .pickerStyle(.automatic)

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
        vc.seekParameters = seekParameters.seekParameters
        vc.repeatMode = urls.count == 1 ? .one : .off
        nav.pushViewController(vc, animated: true)
    }

    private func openSiml() {
        guard
            let host = hostViewController,
            let nav = host.navigationController
        else { return }

        let vcs = [
            PlayerViewController(),
            PlayerViewController(),
            PlayerViewController(),
            PlayerViewController(),
            PlayerViewController(),
            PlayerViewController()
        ]

        for vc in vcs {
            vc.repeatMode = .all
            vc.seekParameters = seekParameters.seekParameters
            vc.videoUrls = urls.map { URL(string: $0)! }
        }

        let container = ContnainerVC(vcs: vcs)
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
        super.viewDidLayoutSubviews()

        let cols = 2
        let rows = 3
        let cellW = view.bounds.width / CGFloat(cols)
        let cellH = view.bounds.height / CGFloat(rows)

        for (i, vc) in vcs.prefix(cols * rows).enumerated() {
            let col = i % cols
            let row = i / cols
            vc.view.frame = CGRect(
                x: CGFloat(col) * cellW,
                y: CGFloat(row) * cellH,
                width: cellW,
                height: cellH
            )
        }
    }
}
