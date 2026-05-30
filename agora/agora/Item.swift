//
//  Item.swift
//  agora
//
//  Created by Monster 林 on 2026/5/30.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
