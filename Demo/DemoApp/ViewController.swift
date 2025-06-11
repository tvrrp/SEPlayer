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
    // MARK: – Входные данные
    weak var hostViewController: UIViewController?
    
    // MARK: – Состояние
    @State private var urls: [String] = [
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WeAreGoingOnBullrun.mp4",
        "https://html5demos.com/assets/dizzy.mp4",
        "https://streams.videolan.org/streams/mp4/GHOST_IN_THE_SHELL_V5_DOLBY%20-%203.m4v",
        "https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4",
        "https://github.com/chthomos/video-media-samples/raw/refs/heads/master/big-buck-bunny-1080p-60fps-30sec.mp4",
        "https://storage.googleapis.com/exoplayer-test-media-1/mp4/frame-counter-one-hour.mp4",
    ]
    @State private var newUrl: String = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                
                // Верхняя строка ввода + “Add”
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
                
                // Кнопка “Play”
                Button("Play") {
                    openPlayer(urls: urls)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .navigationTitle("Links")
            .toolbar { EditButton() }
        }
    }
    
    // MARK: – Действия

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
}
