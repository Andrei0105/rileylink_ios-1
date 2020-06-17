//
//  PairPodSetupViewController.swift
//  OmniKitUI
//
//  Created by Pete Schwamb on 9/18/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import UIKit
import LoopKit
import LoopKitUI
import RileyLinkKit
import OmniKit
import os.log
import AudioToolbox

fileprivate let SystemSound_alarm: SystemSoundID = 1304

class PairPodSetupViewController: SetupTableViewController {
    
    var rileyLinkPumpManager: RileyLinkPumpManager!
    
    var pumpManager: OmnipodPumpManager! {
        didSet {
            if oldValue == nil && pumpManager != nil {
                pumpManagerWasSet()
            }
        }
    }

    private let log = OSLog(category: "PairPodSetupViewController")

    // MARK: -
    
    @IBOutlet weak var activityIndicator: SetupIndicatorView!
    
    @IBOutlet weak var loadingLabel: UILabel!
    
    private var loadingText: String? {
        didSet {
            tableView.beginUpdates()
            loadingLabel.text = loadingText
            
            let isHidden = (loadingText == nil)
            loadingLabel.isHidden = isHidden
            tableView.endUpdates()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        continueState = .initial
    }
    
    private func pumpManagerWasSet() {
        // Still priming?
        let primeFinishesAt = pumpManager.state.podState?.primeFinishTime
        let currentTime = Date()
        if let finishTime = primeFinishesAt, finishTime > currentTime {
            self.continueState = .pairing
            let delay = finishTime.timeIntervalSince(currentTime)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.continueState = .ready
            }
        }
    }
    
    // MARK: - UITableViewDelegate
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if case .pairing = continueState {
            return
        }
        
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    // MARK: - State
    
    private enum State {
        case initial
        case pairing
        case pairingRetry
        case priming(finishTime: TimeInterval)
        case fault
        case ready
    }
    
    private var continueState: State = .initial {
        didSet {
            log.default("Changed continueState from %{public}@ to %{public}@", String(describing: oldValue), String(describing: continueState))

            switch continueState {
            case .initial:
                activityIndicator.state = .hidden
                footerView.primaryButton.isEnabled = true
                footerView.primaryButton.setPairTitle()
            case .pairing:
                activityIndicator.state = .indeterminantProgress
                footerView.primaryButton.isEnabled = false
                footerView.primaryButton.setPairTitle()
                lastError = nil
                loadingText = LocalizedString("Pairing…", comment: "The text of the loading label when pairing")
            case .pairingRetry:
                activityIndicator.state = .indeterminantProgress
                footerView.primaryButton.isEnabled = false
                footerView.primaryButton.setPairTitle()
                // continue displaying the loadingText which includes includes a message to reposition the RL
            case .priming(let finishTime):
                activityIndicator.state = .timedProgress(finishTime: CACurrentMediaTime() + finishTime)
                footerView.primaryButton.isEnabled = false
                footerView.primaryButton.setPairTitle()
                lastError = nil
                loadingText = LocalizedString("Priming…", comment: "The text of the loading label when priming")
            case .fault:
                activityIndicator.state = .hidden
                footerView.primaryButton.isEnabled = true
                footerView.primaryButton.setDeactivateTitle()
            case .ready:
                activityIndicator.state = .completed
                footerView.primaryButton.isEnabled = true
                footerView.primaryButton.resetTitle()
                lastError = nil
                loadingText = LocalizedString("Primed", comment: "The text of the loading label when pod is primed")
            }
        }
    }
    
    private var lastError: Error? {
        didSet {
            guard oldValue != nil || lastError != nil else {
                return
            }
            
            if let commsError = lastError as? PodCommsError, commsError.possibleWeakCommsCause {
                switch continueState {
                case .pairing:
                    // Received a no response error for the initial pairing attempt.
                    // Replicate the PDM by beeping and displaying a reposition
                    // suggestion to the user and keep trying to pair (by calling pair() again).
                    AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
                    AudioServicesPlayAlertSound(SystemSound_alarm)
                    loadingText = LocalizedString("Communications error!  Please reposition the RileyLink or the pod.\n\nPairing...", comment: "The text string to reposition while continuing to pair after a communications error")
                    self.continueState = .pairingRetry
                    pair()
                    return
                case .pairingRetry:
                    // Received a no response error after the second first pairing attempt.
                    // Replicate the PDM by beeping and prompting the user to move
                    // to a new location and then to try again.
                    AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
                    AudioServicesPlayAlertSound(SystemSound_alarm)
                    loadingText = LocalizedString("Communications error!  Please move to a new area and try again.", comment: "The text string to move to a new area and try again after pairing fails due to a communications error")
                    continueState = .initial
                    return
                default:
                    break
                }
            }

            var errorStrings: [String]
            
            if let error = lastError as? LocalizedError {
                errorStrings = [error.errorDescription, error.failureReason, error.recoverySuggestion].compactMap { $0 }
            } else {
                errorStrings = [lastError?.localizedDescription].compactMap { $0 }
            }
            
            loadingText = errorStrings.joined(separator: ". ") + "."
            
            // If we have an error, update the continue state
            if let podCommsError = lastError as? PodCommsError,
                case PodCommsError.podFault = podCommsError
            {
                continueState = .fault
            } else if lastError != nil {
                continueState = .initial
            }
        }
    }
    
    // MARK: - Navigation
    
    private func navigateToReplacePod() {
        log.default("Navigating to ReplacePod screen")
        performSegue(withIdentifier: "ReplacePod", sender: nil)
    }

    override func continueButtonPressed(_ sender: Any) {
        switch continueState {
        case .initial:
            self.continueState = .pairing
            pair()
        case .ready:
            super.continueButtonPressed(sender)
        case .fault:
            navigateToReplacePod()
        default:
            break
        }

    }
    
    override func cancelButtonPressed(_ sender: Any) {
        let podState = pumpManager.state.podState

        if podState != nil {
            let confirmVC = UIAlertController(pumpDeletionHandler: {
                self.navigateToReplacePod()
            })
            self.present(confirmVC, animated: true) {}
        } else {
            super.cancelButtonPressed(sender)
        }
    }
    
    // MARK: -
    
    private func pair() {

        pumpManager.pairAndPrime() { (result) in
            DispatchQueue.main.async {
                switch result {
                case .success(let finishTime):
                    self.log.default("Pairing succeeded, finishing in %{public}@ sec", String(describing: finishTime))
                    if finishTime > 0 {
                        self.continueState = .priming(finishTime: finishTime)
                        DispatchQueue.main.asyncAfter(deadline: .now() + finishTime) {
                            self.continueState = .ready
                        }
                    } else {
                        self.continueState = .ready
                    }
                case .failure(let error):
                    self.log.default("Pairing failed with error: %{public}@", String(describing: error))
                    self.lastError = error
                }
            }
        }
    }
}

private extension PodCommsError {
    var possibleWeakCommsCause: Bool {
        switch self {
        case .invalidData, .noResponse:
            return true
        default:
            return false
        }
    }
}

private extension SetupButton {
    func setPairTitle() {
        setTitle(LocalizedString("Pair", comment: "Button title to pair with pod during setup"), for: .normal)
    }
    
    func setDeactivateTitle() {
        setTitle(LocalizedString("Deactivate", comment: "Button title to deactivate pod because of fault during setup"), for: .normal)
    }
}

private extension UIAlertController {
    convenience init(pumpDeletionHandler handler: @escaping () -> Void) {
        self.init(
            title: nil,
            message: LocalizedString("Are you sure you want to shutdown this pod?", comment: "Confirmation message for shutting down a pod"),
            preferredStyle: .actionSheet
        )
        
        addAction(UIAlertAction(
            title: LocalizedString("Deactivate Pod", comment: "Button title to deactivate pod"),
            style: .destructive,
            handler: { (_) in
                handler()
        }
        ))
        
        let exit = LocalizedString("Continue", comment: "The title of the continue action in an action sheet")
        addAction(UIAlertAction(title: exit, style: .default, handler: nil))
    }
}
