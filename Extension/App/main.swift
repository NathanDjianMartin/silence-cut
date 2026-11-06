import Cocoa

let app = NSApplication.shared
let alert = NSAlert()
alert.messageText = "SilenceCut est installé"
alert.informativeText = "Ouvrez Final Cut Pro puis le menu Fenêtre > Extensions > SilenceCut."
alert.runModal()
