//
//  SimilarArtistsShelfCell.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 28.02.26.
//  Copyright (c) 2026 Alzimer Ahmed. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import SonicWaveKit
import UIKit

// MARK: - SimilarArtistsShelfCell

/// G20: horizontal "Similar Artists" shelf embedded as a single table row
/// on `ArtistDetailVC`. Stubs that resolve to a local `Artist` navigate on
/// tap; unresolvable ones stay display-only cards (generated artwork, no
/// fake navigation).
final class SimilarArtistsShelfCell: UITableViewCell {
  static let reuseID = "SimilarArtistsShelfCell"
  static let shelfHeight: CGFloat = 150.0
  private static let cellWidth: CGFloat = 100.0

  private var stubs = [ArtistStub]()
  var account: Account?
  var onSelectArtist: ((Artist) -> ())?

  private lazy var collectionView: UICollectionView = {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.itemSize = CGSize(width: Self.cellWidth, height: Self.shelfHeight - 16)
    layout.minimumInteritemSpacing = 12
    layout.sectionInset = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
    let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .clear
    view.showsHorizontalScrollIndicator = false
    view.register(DiscoveryShelfCell.self, forCellWithReuseIdentifier: DiscoveryShelfCell.reuseID)
    view.dataSource = self
    view.delegate = self
    return view
  }()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    contentView.addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      collectionView.topAnchor.constraint(equalTo: contentView.topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      collectionView.heightAnchor.constraint(equalToConstant: Self.shelfHeight),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func display(stubs: [ArtistStub], account: Account) {
    self.stubs = stubs
    self.account = account
    collectionView.reloadData()
  }
}

extension SimilarArtistsShelfCell: UICollectionViewDataSource, UICollectionViewDelegate {
  func collectionView(
    _ collectionView: UICollectionView,
    numberOfItemsInSection section: Int
  )
    -> Int {
    stubs.count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  )
    -> UICollectionViewCell {
    guard let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: DiscoveryShelfCell.reuseID,
      for: indexPath
    ) as? DiscoveryShelfCell else { return UICollectionViewCell() }
    guard let stub = stubs.element(at: indexPath.item), let account else { return cell }
    if let id = stub.id,
       let artist = appDelegate.storage.main.library.getArtist(for: account, id: id) {
      cell.display(entity: artist, title: stub.name, subtitle: nil)
    } else {
      cell.display(artworkType: .artist, title: stub.name, subtitle: nil)
    }
    return cell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    collectionView.deselectItem(at: indexPath, animated: true)
    guard let stub = stubs.element(at: indexPath.item), let id = stub.id, let account,
          let artist = appDelegate.storage.main.library.getArtist(for: account, id: id)
    else { return }
    onSelectArtist?(artist)
  }
}
