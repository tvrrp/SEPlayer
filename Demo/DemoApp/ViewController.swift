//
//  ViewController.swift
//  DemoApp
//
//  Created by Damir Yackupov on 09.06.2025.
//

import SEPlayer
import SwiftUI
import UIKit

final class ViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let rootView = UrlListScreen(hostViewController: self)
        let hosting = UIHostingController(rootView: rootView)

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        hosting.didMove(toParent: self)
    }
}

struct UrlListScreen: View {
    weak var hostViewController: UIViewController?

    @State private var categories: [ContentCategory] = ContentCategory.samplesWithBundledFiles
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
            case .default: SeekParameters.default
            case .exact: SeekParameters.exact
            case .closestSync: SeekParameters.closestSync
            case .previousSync: SeekParameters.previousSync
            case .nextSync: SeekParameters.nextSync
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
                    ForEach($categories) { $category in
                        Section {
                            ForEach(category.items) { item in
                                Text(item.url)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .contentShape(Rectangle())
                                    .onTapGesture { openPlayer(urls: item.playlistUrls) }
                            }
                            .onDelete { category.items.remove(atOffsets: $0) }
                            .onMove { category.items.move(fromOffsets: $0, toOffset: $1) }
                        } header: {
                            HStack {
                                Text(category.title)
                                Spacer()
                                Text(category.format.rawValue)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)

                HStack {
                    Button("Play") {
                        openPlayer(urls: allUrls)
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

    /// The urls of every item of every category, in order.
    private var allUrls: [String] {
        categories.flatMap(\.items).flatMap(\.playlistUrls)
    }

    /// Adds the typed url to the category of added urls, which comes first once there is one.
    private func addUrl() {
        let trimmed = newUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = ContentItem(url: trimmed)
        if let index = categories.firstIndex(where: { $0.title == ContentCategory.customTitle }) {
            categories[index].items.append(item)
        } else {
            var category = ContentCategory(ContentCategory.customTitle, format: Self.format(of: trimmed), urls: [])
            category.items = [item]
            categories.insert(category, at: 0)
        }
        newUrl = ""
    }

    /// The format of a typed url, from its extension.
    private static func format(of url: String) -> ContentFormat {
        URL(string: url)?.pathExtension.lowercased() == "m3u8" ? .hlsOnDemand : .progressive
    }

    private func openPlayer(urls: [String]) {
        guard
            let host = hostViewController,
            let nav = host.navigationController else { return }

        let sb = UIStoryboard(name: "Main", bundle: .main)
        guard
            let vc = sb.instantiateViewController(withIdentifier: "PlayerViewController")
            as? PlayerViewController else { return }

        vc.videoUrls = urls.compactMap(URL.init(string:))
        vc.seekParameters = seekParameters.seekParameters
        vc.repeatMode = urls.count == 1 ? .one : .off
        nav.pushViewController(vc, animated: true)
    }

    private func openSiml() {
        guard
            let host = hostViewController,
            let nav = host.navigationController else { return }

        let vcs = (0 ..< 6).compactMap { _ in (try? playerFactory.buildPlayer()).map(PlayerViewController.init(player:)) }

        for vc in vcs {
            vc.seekParameters = seekParameters.seekParameters
            vc.videoUrls = allUrls.compactMap(URL.init(string:))
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

    @available(*, unavailable)
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
