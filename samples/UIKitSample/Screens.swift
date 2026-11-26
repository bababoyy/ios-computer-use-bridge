import UIKit

/// Ana menü: tablo hücresi seçimi (table-select) yolunu test eder.
final class MenuViewController: UITableViewController {
    private let items: [(title: String, id: String, make: () -> UIViewController)] = [
        ("Counter", "menu.counter", { CounterViewController() }),
        ("Switch", "menu.switch", { SwitchViewController() }),
        ("Form", "menu.form", { FormViewController() }),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit Sample"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = items[indexPath.row].title
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = items[indexPath.row].id
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(items[indexPath.row].make(), animated: true)
    }
}

private func makeStack(_ views: [UIView], in vc: UIViewController) {
    vc.view.backgroundColor = .systemBackground
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = .vertical
    stack.spacing = 20
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    vc.view.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.centerYAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.centerYAnchor),
        stack.leadingAnchor.constraint(equalTo: vc.view.layoutMarginsGuide.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: vc.view.layoutMarginsGuide.trailingAnchor),
    ])
}

private func makeButton(_ title: String, id: String, prominent: Bool = true, action: @escaping () -> Void) -> UIButton {
    var config: UIButton.Configuration = prominent ? .filled() : .bordered()
    config.title = title
    let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    button.accessibilityIdentifier = id
    return button
}

private func makeLabel(_ text: String, id: String, style: UIFont.TextStyle = .title1) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .preferredFont(forTextStyle: style)
    label.accessibilityIdentifier = id
    return label
}

/// Sayaç: UIControl eylemi (control-action) yolunu test eder.
final class CounterViewController: UIViewController {
    private var count = 0 { didSet { label.text = "Count: \(count)" } }
    private lazy var label = makeLabel("Count: 0", id: "counterLabel")

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Counter"
        makeStack([
            label,
            makeButton("Increment", id: "incrementButton") { [weak self] in self?.count += 1 },
            makeButton("Reset", id: "resetButton", prominent: false) { [weak self] in self?.count = 0 },
        ], in: self)
    }
}

/// Anahtar: UISwitch (switch-toggle) yolunu test eder.
final class SwitchViewController: UIViewController {
    private let toggle = UISwitch()
    private lazy var status = makeLabel("Feature: off", id: "featureStatus", style: .title2)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Switch"
        toggle.accessibilityIdentifier = "featureSwitch"
        toggle.accessibilityLabel = "Feature"
        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            status.text = toggle.isOn ? "Feature: on" : "Feature: off"
        }, for: .valueChanged)
        makeStack([toggle, status], in: self)
    }
}

/// Form: metin alanına odaklanma (focus) yolunu test eder. Metin girme Faz 2'de.
final class FormViewController: UIViewController {
    private let field = UITextField()
    private lazy var greeting = makeLabel("-", id: "greetingLabel", style: .title2)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Form"
        field.placeholder = "Name"
        field.borderStyle = .roundedRect
        field.accessibilityIdentifier = "nameField"
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        makeStack([
            field,
            makeButton("Submit", id: "submitButton") { [weak self] in
                guard let self else { return }
                let name = field.text?.isEmpty == false ? field.text! : "anonymous"
                greeting.text = "Hello, \(name)"
            },
            greeting,
        ], in: self)
    }
}
