import CaptureCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Form {
            Section("Запись") {
                Picker("Кодек", selection: $controller.settings.codec) {
                    ForEach(CaptureCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                TextField("Папка записи", text: $controller.settings.destinationPath)
                TextField("Проект", text: $controller.settings.projectName)
                TextField("Камера", text: $controller.settings.cameraLabel)
            }
            Section("Именование") {
                TextField("Шаблон имени", text: $controller.settings.namingTemplate)
                Text("Плейсхолдеры: \(NamingEngine.placeholders.joined(separator: " "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Детекция дублей") {
                Picker("Режим", selection: $controller.settings.detectionMode) {
                    Text("Авто (VANC + таймкод)").tag(RecDetectionMode.auto)
                    Text("Только бегущий таймкод").tag(RecDetectionMode.timecodeRun)
                    Text("Только вручную").tag(RecDetectionMode.manual)
                }
                Stepper("Старт: \(controller.settings.startDebounceFrames) кадр(ов)",
                        value: $controller.settings.startDebounceFrames, in: 1...30)
                Stepper("Стоп: \(controller.settings.stopDebounceFrames) кадр(ов)",
                        value: $controller.settings.stopDebounceFrames, in: 1...60)
                Text("Для авто-детекции по таймкоду камера должна писать TC в режиме Rec Run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}
