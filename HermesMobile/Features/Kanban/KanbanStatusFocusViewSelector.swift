import SwiftUI
import UIKit


extension KanbanStatusFocusView {
    var statusSelector: some View {
        KanbanStatusSelector(model: model)
    }

    private struct KanbanStatusSelector: UIViewRepresentable {
        @Bindable var model: KanbanFeatureState
        @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 56

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIView(context: Context) -> UIScrollView {
            let scrollView = KanbanStatusScrollView()
            scrollView.alwaysBounceHorizontal = false
            scrollView.alwaysBounceVertical = false
            scrollView.delaysContentTouches = false
            scrollView.isDirectionalLockEnabled = true
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.refreshControl = nil
            scrollView.accessibilityIdentifier = "KanbanStatusSelector"
            context.coordinator.install(in: scrollView)
            return scrollView
        }

        func updateUIView(_ scrollView: UIScrollView, context: Context) {
            context.coordinator.parent = self
            context.coordinator.update(height: height)
        }

        @MainActor
        final class KanbanStatusScrollView: UIScrollView {
            override func touchesShouldCancel(in view: UIView) -> Bool {
                true
            }
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: UIScrollView,
            context: Context
        ) -> CGSize? {
            CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: height)
        }

        @MainActor
        final class Coordinator: NSObject {
            var parent: KanbanStatusSelector
            private let stackView = UIStackView()
            private var controls: [String: KanbanStatusControl] = [:]
            private var orderedStatuses: [String] = []

            init(parent: KanbanStatusSelector) {
                self.parent = parent
            }

            func install(in scrollView: UIScrollView) {
                stackView.axis = .horizontal
                stackView.alignment = .center
                stackView.spacing = 8
                stackView.translatesAutoresizingMaskIntoConstraints = false
                scrollView.addSubview(stackView)
                let tapRecognizer = UITapGestureRecognizer(
                    target: self,
                    action: #selector(selectStatus(at:))
                )
                tapRecognizer.cancelsTouchesInView = false
                scrollView.addGestureRecognizer(tapRecognizer)

                NSLayoutConstraint.activate([
                    stackView.leadingAnchor.constraint(
                        equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                        constant: 16
                    ),
                    stackView.trailingAnchor.constraint(
                        equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                        constant: -16
                    ),
                    stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                    stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                    stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
                ])
            }

            func update(height: CGFloat) {
                let statuses = parent.model.availableStatuses
                if statuses != orderedStatuses {
                    rebuild(statuses)
                }

                let controlHeight = max(44, height - 12)
                for status in statuses {
                    let presentation = KanbanStatusPresentation(status)
                    controls[status]?.update(
                        title: presentation.title,
                        count: parent.model.statusCount(status),
                        color: UIColor(presentation.color),
                        isSelected: parent.model.selectedStatus == status,
                        height: controlHeight
                    )
                }
            }

            private func rebuild(_ statuses: [String]) {
                orderedStatuses = statuses
                for view in stackView.arrangedSubviews {
                    stackView.removeArrangedSubview(view)
                    view.removeFromSuperview()
                }
                controls.removeAll()

                for status in statuses {
                    let control = KanbanStatusControl()
                    control.status = status
                    control.addTarget(
                        self,
                        action: #selector(selectStatus(_:)),
                        for: [.touchUpInside, .primaryActionTriggered]
                    )
                    stackView.addArrangedSubview(control)
                    controls[status] = control
                }
            }

            @objc
            private func selectStatus(_ sender: KanbanStatusControl) {
                parent.model.selectedStatus = sender.status
            }

            @objc
            private func selectStatus(at recognizer: UITapGestureRecognizer) {
                guard recognizer.state == .ended else { return }
                let location = recognizer.location(in: stackView)
                guard let control = stackView.arrangedSubviews
                    .compactMap({ $0 as? KanbanStatusControl })
                    .first(where: { $0.frame.contains(location) })
                else { return }
                parent.model.selectedStatus = control.status
            }
        }

        @MainActor
        final class KanbanStatusControl: UIControl {
            var status = ""
            private let dotView = UIView()
            private let titleLabel = UILabel()
            private let countLabel = UILabel()
            private let stackView = UIStackView()
            private var heightConstraint: NSLayoutConstraint?

            override init(frame: CGRect) {
                super.init(frame: frame)
                isAccessibilityElement = true
                layer.cornerCurve = .continuous

                dotView.translatesAutoresizingMaskIntoConstraints = false
                dotView.layer.cornerRadius = 4
                NSLayoutConstraint.activate([
                    dotView.widthAnchor.constraint(equalToConstant: 8),
                    dotView.heightAnchor.constraint(equalToConstant: 8)
                ])

                titleLabel.adjustsFontForContentSizeCategory = true
                titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                countLabel.adjustsFontForContentSizeCategory = true
                countLabel.font = .monospacedDigitSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                    weight: .regular
                )
                countLabel.textColor = .secondaryLabel

                stackView.axis = .horizontal
                stackView.alignment = .center
                stackView.spacing = 6
                stackView.translatesAutoresizingMaskIntoConstraints = false
                stackView.addArrangedSubview(dotView)
                stackView.addArrangedSubview(titleLabel)
                stackView.addArrangedSubview(countLabel)
                addSubview(stackView)

                NSLayoutConstraint.activate([
                    stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                    stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                    stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
                ])
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func update(
                title: String,
                count: Int,
                color: UIColor,
                isSelected: Bool,
                height: CGFloat
            ) {
                titleLabel.text = title
                let preferredTitleFont = UIFont.preferredFont(forTextStyle: .subheadline)
                titleLabel.font = .systemFont(
                    ofSize: preferredTitleFont.pointSize,
                    weight: isSelected ? .semibold : .regular
                )
                countLabel.font = .monospacedDigitSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                    weight: .regular
                )
                countLabel.text = "\(count)"
                dotView.backgroundColor = color
                self.isSelected = isSelected
                backgroundColor = isSelected ? .secondarySystemFill : .clear
                layer.cornerRadius = height / 2
                accessibilityLabel = String.localizedStringWithFormat(
                    String(localized: "%@, %@"),
                    title,
                    KanbanCountFormatter.cards(count)
                )
                accessibilityTraits = isSelected ? [.button, .selected] : .button

                if heightConstraint?.constant != height {
                    heightConstraint?.isActive = false
                    heightConstraint = heightAnchor.constraint(equalToConstant: height)
                    heightConstraint?.isActive = true
                }
            }
        }
    }
}
