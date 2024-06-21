//
//  SendUtxoView.swift
//  Unify
//
//  Created by Peter Denton on 6/18/24.
//

import Foundation
import SwiftUI
import NostrSDK
import LibWally

struct SpendableUtxosView: View, DirectMessageEncrypting {
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    private let urlString = UserDefaults.standard.string(forKey: "nostrRelay") ?? "wss://relay.damus.io"
    
    @State private var spendableBalance = 0.0
    @State private var signedRawTx: String?
    @State private var txid: String?
    @State private var copied = false
    @State private var signedPsbt: PSBT?
    @State private var proposalPsbtReceived = false
    @State private var ourKeypair: Keypair?
    @State private var recipientsPubkey: PublicKey?
    @State private var paymentBroadcastByRecipient = false
    @State private var selection = Set<Utxo>()
    @State private var selectedUtxosToConsume: [Utxo] = []
    @State private var waitingForResponse = false
    @State private var errorToDisplay = ""
    @State private var showError = false
    
    let utxos: [Utxo]
    let invoice: Invoice
    
    init(utxos: [Utxo], invoice: Invoice) {
        self.utxos = utxos
        self.invoice = invoice
    }
    
    var body: some View {
        if !waitingForResponse {
            
            if let signedRawTx = signedRawTx,
               let signedPsbt = signedPsbt,
               let ourKeypair = ourKeypair,
               let recipientsPubkey = recipientsPubkey {
                Form() {
                    Text("Payjoin proposal received from the recipient ✓")
                                        
                    NavigationLink() {
                        SignedProposalView(signedRawTx: signedRawTx,
                                           invoice: invoice,
                                           ourKeypair: ourKeypair,
                                           recipientsPubkey: recipientsPubkey,
                                           psbtProposal: signedPsbt)
                    } label: {
                        Text("Tap to view Payjoin Proposal")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.bordered)
                }
                .formStyle(.grouped)
                
                
            } else {
                List(selection: $selection) {
                    Section("Invoice amount") {
                        Label(invoice.amount!.btcBalanceWithSpaces, systemImage: "bitcoinsign.circle")
                    }
                    
                    Section("Total spendable balance") {
                        Label {
                            Text(spendableBalance.btcBalanceWithSpaces)
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "bitcoinsign.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }
                
                    Section() {
                        ForEach(utxos, id:\.self) { utxo in
                            Text(utxo.address! + " " + utxo.amount!.btcBalanceWithSpaces)
                                .onAppear {
                                    spendableBalance += utxo.amount ?? 0.0
                                }
                        }
                        
                    } header: {
                        Text("Select UTXOs to Payjoin")
                        
                    } footer: {
                        Button {
                            var totalAmtSelected = 0.0
                            
                            for utxo in selection {
                                print("selected utxo: \(utxo.address! + " " + utxo.amount!.btcBalanceWithSpaces)")
                                totalAmtSelected += utxo.amount!
                                selectedUtxosToConsume.append(utxo)
                            }
                            
                            if totalAmtSelected > invoice.amount! {
                                payInvoice(invoice: invoice, selectedUtxos: selectedUtxosToConsume, utxos: utxos)
                            } else {
                                showError(desc: "Select more utxos to cover invoice amount.")
                            }
                            
                            
                            
                        } label: {
                            Text("Payjoin \(selection.count) utxos")
                        }
                        .buttonStyle(.bordered)
                    }
                }
#if os(iOS)
                        .listStyle(InsetGroupedListStyle())
                        .environment(\.editMode, .constant(EditMode.active))
#endif
                        .alert(errorToDisplay, isPresented: $showError) {
                            Button("OK", role: .cancel) {}
                        }
                        
#if os(macOS)
                        Text("Hold the command button to select multiple utxos.")
                            .foregroundStyle(.secondary)
#endif
            }
                
        } else {
            ProgressView()
                .alert("Payment broadcast by sender ✓", isPresented: $paymentBroadcastByRecipient) {
                    Button("OK", role: .cancel) {
                        self.presentationMode.wrappedValue.dismiss()
                    }
                }
                .alert(errorToDisplay, isPresented: $showError) {
                    Button("OK", role: .cancel) {}
                }
        }
    }
    
    
    private func showError(desc: String) {
        errorToDisplay = desc
        waitingForResponse = false
        showError = true
    }
    
    
    private func payInvoice(invoice: Invoice, selectedUtxos: [Utxo], utxos: [Utxo]) {
        self.waitingForResponse = true
        let networkSetting = UserDefaults.standard.object(forKey: "network") as? String ?? "Signet"
        var network: Network = .testnet
        
        if networkSetting == "Mainnet" {
            network = .mainnet
        }
        
        var inputs: [[String: Any]] = []
        
        for selectedUtxo in selectedUtxos {
            inputs.append(["txid": selectedUtxo.txid, "vout": selectedUtxo.vout])
        }
        
        let outputs = [[invoice.address!: "\(invoice.amount!)"]]
        
        var options:[String:Any] = [:]
        options["includeWatching"] = true
        options["replaceable"] = true
        options["add_inputs"] = true
        
        let dict: [String:Any] = [
            "inputs": inputs,
            "outputs": outputs,
            "options": options,
            "bip32derivs": false
        ]
        
        let p = Wallet_Create_Funded_Psbt(dict)
        
        BitcoinCoreRPC.shared.btcRPC(method: .walletcreatefundedpsbt(param: p)) { (response, errorDesc) in
            guard let response = response as? [String: Any], let psbt = response["psbt"] as? String else {
                showError(desc: errorDesc ?? "Unknown error.")
                
                return
            }
            
            Signer.sign(psbt: psbt, passphrase: nil, completion: { (signedPsbt, rawTx, errorMessage) in
                guard let signedPsbt = signedPsbt else {
                    print("psbt not signed")
                    showError(desc: errorMessage ?? "Unknown signing error.")
                    
                    return
                }
                
                let param = Test_Mempool_Accept(["rawtxs":[rawTx]])
                
                BitcoinCoreRPC.shared.btcRPC(method: .testmempoolaccept(param)) { (response, errorDesc) in
                    guard let response = response as? [[String: Any]],
                          let allowed = response[0]["allowed"] as? Bool, allowed else {
                        showError(desc: errorMessage ?? "Unknown error testmempoolaccept.")
                        
                        return
                    }
                    
                    guard let ourKeypair = Keypair() else {
                        showError(desc: "Could not generate keypair.")
                        
                        return
                    }
                    
                    self.ourKeypair = ourKeypair
                    
                    guard let recipientsNpub = invoice.recipientsNpub else {
                        showError(desc: "Inavlid npub.")
                        
                        return
                    }
                    
                    guard let recipientsPubkey = PublicKey(npub: recipientsNpub) else {
                        showError(desc: "Inavlid public key.")
                        
                        return
                    }
                    
                    self.recipientsPubkey = recipientsPubkey
                                        
                    let unencryptedContent = [
                        "psbt": signedPsbt,
                        "parameters": [
                            //                            "version": 1,
                            //                            "maxAdditionalFeeContribution": 1000,
                            //                            "additionalFeeOutputIndex": 0,
                            //                            "minFeeRate": 10,
                            //                            "disableOutputSubstitution": true
                        ]
                    ]
                    
                    guard let jsonData = try? JSONSerialization.data(withJSONObject: unencryptedContent, options: .prettyPrinted) else {
                        showError(desc: "Converting to jsonData failing...")
                        
                        return
                    }
                    
                    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                        showError(desc: "Converting to json string failed.")
                        
                        return
                    }
                    
                    guard let encEvent = try? encrypt(content: jsonString,
                                                      privateKey: ourKeypair.privateKey,
                                                      publicKey: recipientsPubkey) else {
                        showError(desc: "Encrypting event failed.")
                        
                        return
                    }
                    
                    let urlString = UserDefaults.standard.string(forKey: "nostrRelay") ?? "wss://relay.damus.io"
                    
                    StreamManager.shared.closeWebSocket()
                    
                    StreamManager.shared.openWebSocket(relayUrlString: urlString, peerNpub: recipientsNpub, p: nil)
                    
                    StreamManager.shared.eoseReceivedBlock = { _ in
                        StreamManager.shared.writeEvent(content: encEvent, recipientNpub: recipientsNpub, ourKeypair: ourKeypair)
                        #if DEBUG
                        print("SEND: \(encEvent)")
                        #endif
                    }
                    
                    StreamManager.shared.errorReceivedBlock = { nostrError in
                        showError(desc: "Nostr received error: \(nostrError)")
                    }
                    
                    StreamManager.shared.onDoneBlock = { nostrResponse in
                        guard let content = nostrResponse.content else {
                            guard let nostrErr = nostrResponse.errorDesc, nostrErr != "" else {
                                
                                return
                            }
                            
                            showError(desc: nostrErr)
                            
                            return
                        }
                        
                        
                        guard let decryptedMessage = try? decrypt(encryptedContent: content,
                                                                  privateKey: ourKeypair.privateKey,
                                                                  publicKey: recipientsPubkey) else {
                            showError(desc: "Failed decrypting.")
                            
                            return
                        }
                        
                        print("decryptedMessage: \(decryptedMessage)")
                        
                        if decryptedMessage == "Payment broadcast by recipient ✓" {
                            paymentBroadcastByRecipient = true
                            
                            return
                        }
                        
                        guard let decryptedMessageData = decryptedMessage.data(using: .utf8) else {
                            showError(desc: "Failed converting encrypted message to utf8 data.")
                            
                            return
                        }
                        
                        guard let dictionary =  try? JSONSerialization.jsonObject(with: decryptedMessageData, options: [.allowFragments]) as? [String: Any] else {
                            showError(desc: "Converting to dictionary failed")
                            
                            return
                        }
                        
                        let eventContent = EventContent(dictionary)
                        
                        guard let payjoinProposalBase64 = eventContent.psbt else {
                            showError(desc: "No psbt in event content.")
                            
                            return
                        }
                                                
                        if let payjoinProposal = try? PSBT(psbt: payjoinProposalBase64, network: network),
                           let originalPsbt = try? PSBT(psbt: psbt, network: network) {
                            // now we inpsect it and sign it.
                            // Verify that the absolute fee of the payjoin proposal is equals or higher than the original PSBT.
                            let payjoinProposalAbsoluteFee = Double(payjoinProposal.fee!) / 100000000.0
                            let originalPsbtAbsFee = Double(originalPsbt.fee!) / 100000000.0
                            
                            guard payjoinProposalAbsoluteFee >= originalPsbtAbsFee else {
                                showError(desc: "Fee is smaller then original psbt, ignore.")
                                
                                return
                            }
                            
                            let paramProposal = Decode_Psbt(["psbt": payjoinProposal.description])
                            
                            BitcoinCoreRPC.shared.btcRPC(method: .decodepsbt(param: paramProposal)) { (responseProp, errorDesc) in
                                guard let responseProp = responseProp as? [String: Any] else {
                                    showError(desc: errorDesc ?? "Unknown error, decodepsbt.")
                                    
                                    return
                                }
                                
                                let decodedPayjoinProposal = DecodedPsbt(responseProp)
                                let paramOrig = Decode_Psbt(["psbt": originalPsbt.description])
                                
                                BitcoinCoreRPC.shared.btcRPC(method: .decodepsbt(param: paramOrig)) { (responseOrig, errorDesc) in
                                    guard let responseOrig = responseOrig as? [String: Any] else {
                                        showError(desc: errorDesc ?? "Unknown error, decodepsbt.")
                                        
                                        return
                                    }
                                    
                                    let decodedOriginalPsbt = DecodedPsbt(responseOrig)
                                    
                                    guard decodedPayjoinProposal.txLocktime == decodedOriginalPsbt.txLocktime else {
                                        showError(desc: "Locktimes don't match.")
                                        
                                        return
                                    }
                                    
                                    guard decodedOriginalPsbt.psbtVersion == decodedPayjoinProposal.psbtVersion else {
                                        showError(desc: "Psbt versions don't match.")
                                        
                                        return
                                    }
                                    
                                    var proposedPsbtIncludesOurInput = false
                                    var additionaInputPresent = false
                                    
                                    for proposedInput in decodedPayjoinProposal.txInputs {
                                        for selectedUtxo in selectedUtxos {
                                            if proposedInput["txid"] as! String == selectedUtxo.txid && proposedInput["vout"] as! Int == selectedUtxo.vout {
                                                proposedPsbtIncludesOurInput = true
                                            }
                                        }
                                        
                                        // loop utxos to ensure no other inputs belong to us.
                                        for ourUtxo in utxos {
                                            for selectedUtxo in selectedUtxos {
                                                if ourUtxo.txid != selectedUtxo.txid,
                                                   ourUtxo.vout != selectedUtxo.vout,
                                                   ourUtxo.txid == proposedInput["txid"] as! String,
                                                   ourUtxo.vout == proposedInput["vout"] as! Int {
                                                    
                                                    showError(desc: "Proposed input we didn't add is present.")
                                                    print(ourUtxo.txid + ":" + "\(ourUtxo.vout)")
                                                    additionaInputPresent = true
                                                }
                                            }
                                        }
                                    }
                                    
                                    guard !additionaInputPresent else {
                                        showError(desc: "Yikes, this psbt is trying to get us to sign an input of ours that we didn't add...")
                                        
                                        return
                                    }
                                    
                                    guard proposedPsbtIncludesOurInput else {
                                        showError(desc: "ProposedPsbt does not include the original input.")
                                        
                                        return
                                    }
                                    
                                    // Check that the sender's inputs' sequence numbers are unchanged.
                                    var sendersSeqNumUnChanged = true
                                    var sameSeqNums = true
                                    var prevSeqNum: Int? = nil
                                    for originalInput in decodedOriginalPsbt.txInputs {
                                        for proposedInput in decodedPayjoinProposal.txInputs {
                                            let seqNum = proposedInput["sequence"] as! Int
                                            
                                            if let prevSeqNum = prevSeqNum {
                                                if !(prevSeqNum == seqNum) {
                                                    sameSeqNums = false
                                                }
                                            } else {
                                                prevSeqNum = seqNum
                                            }
                                            
                                            if originalInput["txid"] as! String == proposedInput["txid"] as! String,
                                               originalInput["vout"] as! Int == proposedInput["vout"] as! Int {
                                                if !(originalInput["sequence"] as! Int == proposedInput["sequence"] as! Int) {
                                                    sendersSeqNumUnChanged = false
                                                }
                                            }
                                        }
                                    }
                                    
                                    guard sameSeqNums else {
                                        showError(desc: "Sequence numbers dissimiliar.")
                                        
                                        return
                                    }
                                    
                                    guard sendersSeqNumUnChanged else {
                                        showError(desc: "Sequence numbers changed.")
                                        
                                        return
                                    }
                                    
                                    var inputsAreSegwit = true
                                    
                                    for input in payjoinProposal.inputs {
                                        if !input.isSegwit {
                                            inputsAreSegwit = false
                                        }
                                    }
                                    
                                    var outputsAreSegwit = true
                                    var originalOutputChanged = true
                                    
                                    for proposedOutput in payjoinProposal.outputs {
                                        if !(proposedOutput.txOutput.scriptPubKey.type == .payToWitnessPubKeyHash) {
                                            outputsAreSegwit = false
                                        }
                                        
                                        if proposedOutput.txOutput.address == invoice.address!,
                                           Double(proposedOutput.txOutput.amount) / 100000000.0 == invoice.amount! {
                                            originalOutputChanged = false
                                        }
                                    }
                                    
                                    var originalOutputsIncluded = false
                                    
                                    for (i, originalOutput) in originalPsbt.outputs.enumerated() {
                                        var outputsMatch = false
                                        
                                        for proposedOutput in payjoinProposal.outputs {
                                            if proposedOutput.txOutput.amount == originalOutput.txOutput.amount,
                                               proposedOutput.txOutput.address == originalOutput.txOutput.address {
                                                outputsMatch = true
                                            }
                                        }
                                        
                                        if outputsMatch && i + 1 == originalPsbt.outputs.count {
                                            originalOutputsIncluded = outputsMatch
                                        }
                                    }
                                    
                                    guard originalOutputsIncluded else {
                                        showError(desc: "Not all original outputs included.")
                                        
                                        return
                                    }
                                    
                                    guard !originalOutputChanged else {
                                        showError(desc: "Yikes, someone altered the original invoice output.")
                                              
                                        return
                                    }
                                    
                                    guard inputsAreSegwit, outputsAreSegwit else {
                                        showError(desc: "Somehting not segwit.")
                                        
                                        return
                                    }
                                    
                                    Signer.sign(psbt: payjoinProposal.description, passphrase: nil) { (psbt, rawTx, errorMessage) in
                                        guard let rawTx = rawTx, let signedPsbt = psbt else {
                                            showError(desc: errorMessage ?? "Unknown error when signing the payjoin proposal.")
                                            
                                            return
                                        }
                                        
                                        let p = Test_Mempool_Accept(["rawtxs": [rawTx]])
                                        
                                        BitcoinCoreRPC.shared.btcRPC(method: .testmempoolaccept(p)) { (response, errorDesc) in
                                            guard let response = response as? [[String: Any]],
                                                  let allowed = response[0]["allowed"] as? Bool,
                                                  allowed else {
                                                showError(desc: errorDesc ?? "Unknown error testmempoolaccept.")
                                                
                                                return
                                            }
                                            
                                            guard let signedPsbt = try? PSBT(psbt: signedPsbt, network: network) else {
                                                showError(desc: "Unable to convert signed base64 to PSBT.")
                                                
                                                return
                                            }
                                            
                                            self.waitingForResponse = false
                                            self.signedPsbt = signedPsbt
                                            self.signedRawTx = rawTx
                                            self.proposalPsbtReceived = true
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            })
        }
    }
}
