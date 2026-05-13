//
//  ConnectivityService.swift
//  AC
//

import Foundation
import Network

final class ConnectivityService {
    static let shared = ConnectivityService()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ac.connectivity.monitor")
    private let stateQueue = DispatchQueue(label: "ac.connectivity.state")
    private var latestStatus: NWPath.Status = .requiresConnection
    private var hasObservedPath = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.stateQueue.async {
                self?.latestStatus = path.status
                self?.hasObservedPath = true
            }
        }
        monitor.start(queue: queue)
    }

    var isInternetReachable: Bool {
        stateQueue.sync {
            guard hasObservedPath else { return true }
            return latestStatus == .satisfied
        }
    }
}
