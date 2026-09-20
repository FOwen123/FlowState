// Opt-in acceptance check against the already-running development app.
// `settings` opens Settings; `voice` checks capture; `hud` also checks control-settings navigation.
// Disable desktop/cloud grants before voice checks. No transcript text is logged.
import AppKit
import ApplicationServices
guard ProcessInfo.processInfo.environment["FLOWSTATE_UI_SMOKE"] == "1" else {
 print("Set FLOWSTATE_UI_SMOKE=1 to interact with the running Flow State app."); exit(2)
}
let mode = CommandLine.arguments.dropFirst().first ?? "settings"
guard ["settings", "voice", "hud"].contains(mode) else { print("Use settings, voice, or hud"); exit(2) }
guard let process = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.flowstate.dev" }) else { fatalError("Flow State is not running") }
let app = AXUIElementCreateApplication(process.processIdentifier)
func attr(_ e: AXUIElement,_ name: String)->CFTypeRef? { var result:CFTypeRef?; AXUIElementCopyAttributeValue(e,name as CFString,&result); return result }
func find(_ e:AXUIElement,_ match:(AXUIElement)->Bool,_ depth:Int=0)->AXUIElement? {
 guard depth<10 else{return nil}; if match(e){return e}
 for c in attr(e,"AXChildren") as? [AXUIElement] ?? [] { if let result=find(c,match,depth+1){return result} };return nil
}
func windows()->[AXUIElement] { attr(app,"AXWindows") as? [AXUIElement] ?? [] }
func voiceStatuses()->[String] {
 var output:[String]=[]
 func visit(_ e:AXUIElement,_ depth:Int) {
  guard depth<10 else{return}
  if attr(e,"AXRole") as? String == "AXStaticText", let text=attr(e,"AXValue") as? String,
     ["Listening —", "Voice status: Listening", "Preparing on-device", "Microphone permission", "Install the selected"].contains(where: { text.hasPrefix($0) }) {output.append(text)}
  for c in attr(e,"AXChildren") as? [AXUIElement] ?? [] {visit(c,depth+1)}
 }
 for w in windows(){visit(w,0)};return output
}
if mode == "settings" {
 for w in windows() where attr(w,"AXTitle") as? String == "Flow State Settings" {
  if let close=attr(w,"AXCloseButton"), CFGetTypeID(close)==AXUIElementGetTypeID(){AXUIElementPerformAction(close as! AXUIElement,kAXPressAction as CFString)}
 }
}
guard let item=find(app,{attr($0,"AXRole") as? String == "AXMenuBarItem" && attr($0,"AXTitle") as? String == "waveform"}) else {fatalError("No Flow State status item")}
let label=mode == "settings" ? "Open settings" : "Start voice session"
func menuButton() -> AXUIElement? { windows().compactMap({find($0,{attr($0,"AXDescription") as? String == label && attr($0,"AXRole") as? String == "AXButton"})}).first }
if menuButton() == nil {
 print("menu press",AXUIElementPerformAction(item,kAXPressAction as CFString).rawValue)
 Thread.sleep(forTimeInterval:0.3)
}
guard let button=menuButton() else { print("Menu button unavailable"); exit(2) }
print("button enabled",attr(button,"AXEnabled") ?? "unknown" as CFString)
print("button press",AXUIElementPerformAction(button,kAXPressAction as CFString).rawValue)
Thread.sleep(forTimeInterval:1.2)
if mode == "settings" {
 let opened=windows().contains{attr($0,"AXTitle") as? String == "Flow State Settings"}
 print("Settings window opened:",opened)
 if !opened {exit(1)}
} else {
 let statuses = voiceStatuses()
 let listening = statuses.contains { $0.contains("Listening") }
 print("Visible listening indicator:", listening)
 var controlsOpened = mode != "hud"
 if mode == "hud", let settings=windows().compactMap({find($0,{attr($0,"AXDescription") as? String == "Open control settings"})}).first {
  print("HUD settings press", AXUIElementPerformAction(settings,kAXPressAction as CFString).rawValue)
  Thread.sleep(forTimeInterval:0.6)
  controlsOpened = windows().contains { w in
   attr(w,"AXTitle") as? String == "Flow State Settings" && find(w,{attr($0,"AXDescription") as? String == "Allow desktop control"}) != nil
  }
  print("Control settings opened:",controlsOpened)
 }
 if let stop=windows().compactMap({find($0,{["Stop listening", "Stop voice session"].contains(attr($0,"AXDescription") as? String ?? "")})}).first { print("Stop press", AXUIElementPerformAction(stop,kAXPressAction as CFString).rawValue) }
 if !listening || !controlsOpened { exit(1) }
}
