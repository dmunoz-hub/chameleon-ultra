package com.demomdl.chameleon

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.platform.LocalContext

class MainActivity : ComponentActivity() {
    private val vm: ChameleonController by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { AppTheme { ChameleonScreen(vm) } }
    }
}

@Composable
private fun AppTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val ctx = LocalContext.current
    val scheme = if (Build.VERSION.SDK_INT >= 31) {
        if (dark) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
    } else {
        if (dark) darkColorScheme() else lightColorScheme()
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

private val blePerms: Array<String> =
    if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

@Composable
private fun ChameleonScreen(vm: ChameleonController) {
    val connected by vm.connected.collectAsState()
    val busy by vm.busy.collectAsState()
    val info by vm.deviceInfo.collectAsState()
    val lastId by vm.lastId.collectAsState()
    val hf by vm.lastHF.collectAsState()
    val foundKey by vm.foundKey.collectAsState()
    val logLines by vm.log.collectAsState()

    val canAct = connected && !busy

    // Inputs
    var mfBlock by remember { mutableStateOf("0") }
    var mfKeyB by remember { mutableStateOf(false) }
    var mfKey by remember { mutableStateOf("FFFFFFFFFFFF") }
    var mfData by remember { mutableStateOf("") }
    var uidHex by remember { mutableStateOf("") }
    var gen1a by remember { mutableStateOf(true) }
    var nrKnownBlock by remember { mutableStateOf("3") }
    var nrKnownB by remember { mutableStateOf(false) }
    var nrKnownKey by remember { mutableStateOf("FFFFFFFFFFFF") }
    var nrTargetBlock by remember { mutableStateOf("4") }
    var nrTargetB by remember { mutableStateOf(false) }
    var dsBlock by remember { mutableStateOf("3") }
    var dsB by remember { mutableStateOf(false) }

    // When a key is recovered/found, drop it into the key field.
    LaunchedEffect(foundKey) { foundKey?.let { mfKey = it } }

    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result.values.all { it }) vm.connect()
    }

    fun kt(b: Boolean) = if (b) KeyType.B else KeyType.A
    fun i(s: String) = s.trim().toIntOrNull() ?: 0

    Scaffold { pad ->
        Column(
            Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Text("Chameleon", style = MaterialTheme.typography.titleLarge)

            // Connection
            SectionCard("Connection") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    StatusDot(connected)
                    Spacer(Modifier.width(8.dp))
                    Text(if (connected) "Connected" else "Not connected", style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.weight(1f))
                    if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                }
                if (info.isNotEmpty()) Text(info, style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { permLauncher.launch(blePerms) }, enabled = !busy, modifier = Modifier.weight(1f)) {
                        Text(if (connected) "Reconnect" else "Connect")
                    }
                    if (connected) OutlinedButton(onClick = { vm.disconnect() }) { Text("Disconnect") }
                }
            }

            // LF
            SectionCard("LF · EM410x → T5577") {
                Text(lastId?.let { "Last ID: $it" } ?: "Present an EM410x tag and tap Read.", style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SmallBtn("Read", canAct, Modifier.weight(1f)) { vm.readEM410x() }
                    SmallBtn("Write + Verify", canAct && lastId != null, Modifier.weight(1f), prominent = true) { vm.writeAndVerify() }
                }
                Hint("Read the source tag → swap in a blank T5577 → Write + Verify re-reads and compares.")
            }

            // HF scan
            SectionCard("HF · ISO 14443-A") {
                if (hf != null) {
                    val t = hf!!
                    Text("UID ${t.uid.hexSpaced()}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                    Text("SAK %02X · ATQA ${t.atqa.hexSpaced()}".format(t.sak), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                    Text("${if (t.clonable) "✅" else "⛔"} ${t.kindName}", style = MaterialTheme.typography.bodyMedium)
                    Hint(t.note)
                } else Text("Scan a 13.56 MHz card to read its UID and type.", style = MaterialTheme.typography.bodySmall)
                SmallBtn("Scan HF tag", canAct, Modifier.fillMaxWidth(), prominent = true) { vm.hfScan() }
            }

            // MIFARE block
            SectionCard("MIFARE Classic block") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    NumField(mfBlock, { mfBlock = it }, "blk", Modifier.width(72.dp))
                    KeyToggle(mfKeyB) { mfKeyB = it }
                    HexField(mfKey, { mfKey = it }, "key — 6 bytes", Modifier.weight(1f))
                }
                HexField(mfData, { mfData = it }, "block data — 16 bytes", Modifier.fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SmallBtn("Read", canAct, Modifier.weight(1f)) { vm.mfRead(i(mfBlock), parseHex(mfKey), kt(mfKeyB)) }
                    SmallBtn("Find key", canAct, Modifier.weight(1f)) { vm.findKey(i(mfBlock), kt(mfKeyB)) }
                    SmallBtn("Write", canAct, Modifier.weight(1f)) { vm.mfWrite(i(mfBlock), parseHex(mfData), parseHex(mfKey), kt(mfKeyB)) }
                }
                Hint("⚠️ Writing block 0 or a sector trailer with wrong data can permanently lock a card.")
            }

            // Magic UID
            SectionCard("Magic UID · block 0") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    HexField(uidHex, { uidHex = it }, "new UID — 4 bytes", Modifier.weight(1f))
                    FilterChip(selected = gen1a, onClick = { gen1a = true }, label = { Text("Gen1a") })
                    FilterChip(selected = !gen1a, onClick = { gen1a = false }, label = { Text("Gen2") })
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SmallBtn("Build block 0", true, Modifier.weight(1f)) {
                        val uid = parseHex(uidHex)
                        if (uid.size == 4) { mfData = ChameleonController.buildBlock0(uid).hex(); mfBlock = "0" }
                    }
                    SmallBtn("Write UID", canAct, Modifier.weight(1f), prominent = true) {
                        vm.writeUid(parseHex(mfData), gen1a, parseHex(mfKey), kt(mfKeyB))
                    }
                }
                Hint("Build block 0 fills the data field above. Gen1a uses the backdoor; Gen2 writes block 0 with the key above.")
            }

            // Key recovery
            SectionCard("Key recovery") {
                Text("Nested (needs one known key)", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Known", style = MaterialTheme.typography.bodySmall)
                    NumField(nrKnownBlock, { nrKnownBlock = it }, "blk", Modifier.width(64.dp))
                    KeyToggle(nrKnownB) { nrKnownB = it }
                    HexField(nrKnownKey, { nrKnownKey = it }, "known key", Modifier.weight(1f))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Target", style = MaterialTheme.typography.bodySmall)
                    NumField(nrTargetBlock, { nrTargetBlock = it }, "blk", Modifier.width(64.dp))
                    KeyToggle(nrTargetB) { nrTargetB = it }
                    SmallBtn("Recover", canAct, Modifier.weight(1f), prominent = true) {
                        vm.recoverNested(i(nrKnownBlock), kt(nrKnownB), parseHex(nrKnownKey), i(nrTargetBlock), kt(nrTargetB))
                    }
                }
                HorizontalDivider()
                Text("Darkside (no known key)", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Target", style = MaterialTheme.typography.bodySmall)
                    NumField(dsBlock, { dsBlock = it }, "blk", Modifier.width(64.dp))
                    KeyToggle(dsB) { dsB = it }
                    SmallBtn("Darkside recover", canAct, Modifier.weight(1f), prominent = true) {
                        vm.recoverDarkside(i(dsBlock), kt(dsB))
                    }
                }
                Hint("Runs the firmware's own solver natively on-device. Acquisition is probabilistic — re-run if it misses. Hardnested tags aren't supported.")
            }

            // Log
            SectionCard("Status log") {
                val listState = rememberLazyListState()
                LaunchedEffect(logLines.size) { if (logLines.isNotEmpty()) listState.animateScrollToItem(logLines.size - 1) }
                LazyColumn(state = listState, modifier = Modifier.fillMaxWidth().height(220.dp)) {
                    items(logLines) { line ->
                        Text(line, fontFamily = FontFamily.Monospace, fontSize = 11.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

// ---- small composables ----

@Composable
private fun SectionCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    ElevatedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            content()
        }
    }
}

@Composable
private fun StatusDot(on: Boolean) {
    Surface(color = if (on) androidx.compose.ui.graphics.Color(0xFF3FB950) else MaterialTheme.colorScheme.outline, shape = androidx.compose.foundation.shape.CircleShape, modifier = Modifier.size(10.dp)) {}
}

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun SmallBtn(label: String, enabled: Boolean, modifier: Modifier = Modifier, prominent: Boolean = false, onClick: () -> Unit) {
    if (prominent) Button(onClick = onClick, enabled = enabled, modifier = modifier) { Text(label, maxLines = 1) }
    else OutlinedButton(onClick = onClick, enabled = enabled, modifier = modifier) { Text(label, maxLines = 1) }
}

@Composable
private fun HexField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier) {
    OutlinedTextField(
        value = value, onValueChange = onChange, placeholder = { Text(placeholder) },
        singleLine = true, textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
        modifier = modifier
    )
}

@Composable
private fun NumField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier) {
    OutlinedTextField(
        value = value, onValueChange = onChange, placeholder = { Text(placeholder) }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        textStyle = MaterialTheme.typography.bodySmall, modifier = modifier
    )
}

@Composable
private fun KeyToggle(isB: Boolean, onChange: (Boolean) -> Unit) {
    Row {
        FilterChip(selected = !isB, onClick = { onChange(false) }, label = { Text("A") })
        Spacer(Modifier.width(4.dp))
        FilterChip(selected = isB, onClick = { onChange(true) }, label = { Text("B") })
    }
}
