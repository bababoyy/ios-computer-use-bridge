import SwiftUI

@main
struct SwiftUISampleApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Ana menü: SwiftUI List içindeki NavigationLink'ler.
struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Counter") { CounterView() }
                    .accessibilityIdentifier("menu.counter")
                NavigationLink("Toggle") { ToggleView() }
                    .accessibilityIdentifier("menu.toggle")
                NavigationLink("Form") { FormView() }
                    .accessibilityIdentifier("menu.form")
            }
            .navigationTitle("SwiftUI Sample")
        }
    }
}

/// Sayaç: SwiftUI Button için accessibilityActivate yolunu test eder.
struct CounterView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("Count: \(count)")
                .font(.largeTitle)
                .accessibilityIdentifier("counterLabel")
            Button("Increment") { count += 1 }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("incrementButton")
            Button("Reset") { count = 0 }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("resetButton")
        }
        .navigationTitle("Counter")
    }
}

struct ToggleView: View {
    @State private var isOn = false

    var body: some View {
        VStack(spacing: 24) {
            Toggle("Feature", isOn: $isOn)
                .accessibilityIdentifier("featureSwitch")
                .padding(.horizontal, 40)
            Text(isOn ? "Feature: on" : "Feature: off")
                .font(.title2)
                .accessibilityIdentifier("featureStatus")
        }
        .navigationTitle("Toggle")
    }
}

struct FormView: View {
    @State private var name = ""
    @State private var greeting = "-"

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .accessibilityIdentifier("nameField")
            Button("Submit") { greeting = "Hello, \(name.isEmpty ? "anonymous" : name)" }
                .accessibilityIdentifier("submitButton")
            Text(greeting)
                .accessibilityIdentifier("greetingLabel")
        }
        .navigationTitle("Form")
    }
}
