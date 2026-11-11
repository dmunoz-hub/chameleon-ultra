//  ContentView.swift
//  Minimal operator UI: Connect, LF clone (Read / Write / Verify), HF scan, status log.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var c: ChameleonController

    // MIFARE block + magic UID inputs
    @State private var mfBlock = "0"
    @State private var mfKeyB = false            // false = key A, true = key B
    @State private var mfKey = "FFFFFFFFFFFF"
    @State private var mfData = ""
    @State private var uidHex = ""
    @State private var magicGen1a = true
    // Nested recovery inputs
    @State private var nrKnownBlock = "3"
    @State private var nrKnownB = false
    @State private var nrKnownKey = "FFFFFFFFFFFF"
    @State private var nrTargetBlock = "4"
    @State private var nrTargetB = false
    // Darkside inputs
    @State private var dsBlock = "3"
    @State private var dsB = false

    private var canAct: Bool { c.isConnected && !c.busy }
    private func u8(_ s: String) -> UInt8 { UInt8(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
    private func kt(_ b: Bool) -> MifareKeyType { b ? .keyB : .keyA }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionCard
                    lfCard
                    hfCard
                    mifareCard
                    magicUidCard
                    recoveryCard
                    logCard
                }
                .padding()
            }
            .navigationTitle("Chameleon LF")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: c.lastFoundKey) { k in
                if let k = k { mfKey = ChameleonFrame.hex(k) }
            }
        }
    }

    // MARK: Connection

    private var connectionCard: some View {
        Card(title: "Connection") {
            HStack {
                Circle()
                    .fill(c.isConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(c.isConnected ? "Connected" : "Not connected")
                    .font(.subheadline)
                Spacer()
                if c.busy { ProgressView().controlSize(.small) }
            }
            if !c.deviceInfo.isEmpty {
                Text(c.deviceInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button {
                    c.connect()
                } label: {
                    Label(c.isConnected ? "Reconnect" : "Connect", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(c.busy)

                if c.isConnected {
                    Button(role: .destructive) { c.disconnect() } label: {
                        Text("Disconnect")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: LF

    private var lfCard: some View {
        Card(title: "LF · EM410x → T5577") {
            if let id = c.lastReadId {
                LabeledRow(label: "Last ID", value: ChameleonFrame.hexSpaced(id), mono: true)
            } else {
                Text("Present an EM410x tag and tap Read.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                ActionButton("Read", "wave.3.right", disabled: !c.isConnected || c.busy) { c.readEM410xButton() }
                ActionButton("Write", "square.and.arrow.down", disabled: !c.isConnected || c.busy || c.lastReadId == nil) { c.writeButton() }
                ActionButton("Verify", "checkmark.seal", disabled: !c.isConnected || c.busy || c.lastReadId == nil) { c.verifyButton() }
            }

            Button {
                c.cloneAndVerify()
            } label: {
                Label("Write + Verify", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(!c.isConnected || c.busy || c.lastReadId == nil)

            Text("Flow: Read the source tag → swap in a blank T5577 → Write → Verify re-reads the card.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: HF

    private var hfCard: some View {
        Card(title: "HF · ISO 14443-A") {
            if let t = c.lastHFTag {
                LabeledRow(label: "UID", value: ChameleonFrame.hexSpaced(t.uid), mono: true)
                LabeledRow(label: "SAK / ATQA", value: "\(ChameleonFrame.hex(t.sak))  /  \(ChameleonFrame.hexSpaced(t.atqa))", mono: true)
                HStack(spacing: 6) {
                    Image(systemName: t.kind.clonable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(t.kind.clonable ? .green : .red)
                    Text(t.kind.name).font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(t.kind.note)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Scan a 13.56 MHz card to read its UID and type.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                ActionButton("Scan", "dot.radiowaves.up.forward", disabled: !c.isConnected || c.busy) { c.hf14aScanButton() }
                ActionButton("Recover keys", "key", disabled: !c.isConnected || c.busy) { c.recoverKeys() }
            }
        }
    }

    // MARK: MIFARE block

    private var mifareCard: some View {
        Card(title: "MIFARE Classic block") {
            HStack {
                TextField("blk", text: $mfBlock).frame(width: 46)
                KeyPicker(sel: $mfKeyB)
                HexField("key — 6 bytes", text: $mfKey)
            }
            HexField("block data — 16 bytes (for write)", text: $mfData)
            HStack {
                SmallButton("Read", disabled: !canAct) { c.mfReadBlockButton(block: u8(mfBlock), key: hexBytes(mfKey), keyType: kt(mfKeyB)) }
                SmallButton("Find key", disabled: !canAct) { c.findKeyButton(block: u8(mfBlock), keyType: kt(mfKeyB)) }
                SmallButton("Write", disabled: !canAct) { c.mfWriteBlockButton(block: u8(mfBlock), data16: hexBytes(mfData), key: hexBytes(mfKey), keyType: kt(mfKeyB)) }
            }
            Note("⚠️ Writing block 0 or a sector trailer with wrong data can permanently lock a card.")
        }
        .textFieldStyle(.roundedBorder)
    }

    // MARK: Magic UID

    private var magicUidCard: some View {
        Card(title: "Magic UID · block 0") {
            HStack {
                HexField("new UID — 4 bytes (e.g. DEADBEEF)", text: $uidHex)
                Picker("", selection: $magicGen1a) { Text("Gen1a").tag(true); Text("Gen2").tag(false) }
                    .pickerStyle(.menu).labelsHidden()
            }
            HStack {
                SmallButton("Build block 0", disabled: false) {
                    let uid = hexBytes(uidHex)
                    if uid.count == 4 { mfData = ChameleonFrame.hex(ChameleonController.buildBlock0(uid: uid)); mfBlock = "0"; c.append("Block 0 built: \(mfData)") }
                    else { c.append("UID must be 4 bytes (8 hex chars).") }
                }
                SmallButton("Write UID", disabled: !canAct, prominent: true) {
                    c.writeUidButton(block0: hexBytes(mfData), gen1a: magicGen1a, key: hexBytes(mfKey), keyType: kt(mfKeyB))
                }
            }
            Note("Build block 0 fills the data field above. Gen1a uses the backdoor unlock; Gen2 writes block 0 with the key above. A normal card rejects the UID write.")
        }
        .textFieldStyle(.roundedBorder)
    }

    // MARK: Key recovery

    private var recoveryCard: some View {
        Card(title: "Key recovery") {
            Text("Nested (needs one known key)").font(.caption.weight(.medium))
            HStack {
                Text("Known").font(.caption2).foregroundStyle(.secondary)
                TextField("blk", text: $nrKnownBlock).frame(width: 46)
                KeyPicker(sel: $nrKnownB)
                HexField("known key", text: $nrKnownKey)
            }
            HStack {
                Text("Target").font(.caption2).foregroundStyle(.secondary)
                TextField("blk", text: $nrTargetBlock).frame(width: 46)
                KeyPicker(sel: $nrTargetB)
                SmallButton("Recover", disabled: !canAct, prominent: true) {
                    c.recoverNestedButton(knownBlock: u8(nrKnownBlock), knownType: kt(nrKnownB), knownKey: hexBytes(nrKnownKey),
                                          targetBlock: u8(nrTargetBlock), targetType: kt(nrTargetB))
                }
            }
            Divider().padding(.vertical, 2)
            Text("Darkside (no known key)").font(.caption.weight(.medium))
            HStack {
                Text("Target").font(.caption2).foregroundStyle(.secondary)
                TextField("blk", text: $dsBlock).frame(width: 46)
                KeyPicker(sel: $dsB)
                SmallButton("Darkside recover", disabled: !canAct, prominent: true) {
                    c.recoverDarksideButton(block: u8(dsBlock), type: kt(dsB))
                }
            }
            Note("Runs the firmware's own solver natively on-device. Acquisition is probabilistic — re-run if it misses. Hardnested tags aren't supported.")
        }
        .textFieldStyle(.roundedBorder)
    }

    // MARK: Log

    private var logCard: some View {
        Card(title: "Status log") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(c.log.enumerated()), id: \.offset) { idx, entry in
                            Text(entry)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.primary)
                                .id(idx)
                        }
                        Color.clear.frame(height: 1).id(-1)
                    }
                }
                .frame(height: 220)
                .onChange(of: c.log.count) { _ in
                    withAnimation { proxy.scrollTo(-1, anchor: .bottom) }
                }
            }
        }
    }
}

// MARK: - Reusable bits

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var mono: Bool = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(.footnote, design: .monospaced) : .footnote)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let disabled: Bool
    let action: () -> Void
    init(_ title: String, _ icon: String, disabled: Bool, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.disabled = disabled; self.action = action
    }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
    }
}

// Parse a hex string (any separators) into bytes.
func hexBytes(_ s: String) -> [UInt8] {
    let h = s.filter { $0.isHexDigit }
    var out = [UInt8](); var i = h.startIndex
    while let j = h.index(i, offsetBy: 2, limitedBy: h.endIndex) {
        if let b = UInt8(h[i..<j], radix: 16) { out.append(b) }
        i = j
    }
    return out
}

private struct KeyPicker: View {
    @Binding var sel: Bool
    var body: some View {
        Picker("", selection: $sel) { Text("A").tag(false); Text("B").tag(true) }
            .pickerStyle(.segmented).frame(width: 76).labelsHidden()
    }
}

private struct HexField: View {
    let placeholder: String
    @Binding var text: String
    init(_ placeholder: String, text: Binding<String>) { self.placeholder = placeholder; _text = text }
    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(.footnote, design: .monospaced))
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.characters)
    }
}

private struct SmallButton: View {
    let title: String
    let disabled: Bool
    let prominent: Bool
    let action: () -> Void
    init(_ title: String, disabled: Bool, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.disabled = disabled; self.prominent = prominent; self.action = action
    }
    var body: some View {
        Button(action: action) { Text(title).font(.caption).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .tint(prominent ? .indigo : .gray)
            .disabled(disabled)
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ContentView().environmentObject(ChameleonController())
}
