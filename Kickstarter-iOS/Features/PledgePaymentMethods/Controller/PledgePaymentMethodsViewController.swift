import KsApi
import Library
import PassKit
import Prelude
import StripePaymentSheet
import UIKit

protocol PledgePaymentMethodsViewControllerDelegate: AnyObject {
  func pledgePaymentMethodsViewController(
    _ viewController: PledgePaymentMethodsViewController,
    didSelectCreditCard paymentSource: PaymentSourceSelected
  )
}

final class PledgePaymentMethodsViewController: UIViewController {
  // MARK: - Properties

  private let dataSource = PledgePaymentMethodsDataSource()

  private lazy var tableView: UITableView = {
    ContentSizeTableView(frame: .zero, style: .plain)
      |> \.separatorInset .~ .zero
      |> \.contentInsetAdjustmentBehavior .~ .never
      |> \.isScrollEnabled .~ false
      |> \.dataSource .~ self.dataSource
      |> \.delegate .~ self
      |> \.rowHeight .~ UITableView.automaticDimension
  }()

  internal weak var delegate: PledgePaymentMethodsViewControllerDelegate?
  internal weak var messageDisplayingDelegate: PledgeViewControllerMessageDisplaying?
  private let viewModel: PledgePaymentMethodsViewModelType =
    PledgePaymentMethodsViewModel(stripeIntentService: StripeIntentService())
  private var paymentSheetFlowController: PaymentSheet.FlowController?

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()

    self.configureSubviews()
    self.setupConstraints()

    self.viewModel.inputs.viewDidLoad()
  }

  private func configureSubviews() {
    _ = (self.tableView, self.view)
      |> ksr_addSubviewToParent()

    self.tableView.registerCellClass(PledgePaymentMethodCell.self)
    self.tableView.registerCellClass(PledgePaymentMethodAddCell.self)
    self.tableView.registerCellClass(PledgePaymentMethodLoadingCell.self)
  }

  private func setupConstraints() {
    _ = (self.tableView, self.view)
      |> ksr_constrainViewToEdgesInParent()
  }

  // MARK: - Bind Styles

  override func bindStyles() {
    super.bindStyles()
    _ = self.view
      |> checkoutBackgroundStyle

    _ = self.tableView
      |> checkoutWhiteBackgroundStyle
  }

  // MARK: - View model

  override func bindViewModel() {
    super.bindViewModel()

    self.viewModel.outputs.reloadPaymentMethods
      .observeForUI()
      .observeValues { [weak self] data in
        guard let self = self else { return }

        let cards = data.existingPaymentMethods
        let paymentSheetCards = data.newPaymentMethods
        let isLoading = data.isLoading
        let selectedPaymentMethod = data.selectedPaymentMethod
        let shouldReload = data.shouldReload

        self.dataSource.load(
          cards,
          paymentSheetCards: paymentSheetCards,
          isLoading: isLoading
        )

        if shouldReload {
          self.tableView.reloadData()
        } else {
          switch selectedPaymentMethod {
          case let .savedCreditCard(selectedCardId, _):
            self.tableView.visibleCells
              .compactMap { $0 as? PledgePaymentMethodCell }
              .forEach { $0.setSelectedCardId(selectedCardId) }
          case .none:
            break
          }
        }
      }

    self.viewModel.outputs.notifyDelegateLoadPaymentMethodsError
      .observeForUI()
      .observeValues { [weak self] errorMessage in
        guard let self = self else { return }
        self.messageDisplayingDelegate?.pledgeViewController(self, didErrorWith: errorMessage, error: nil)
      }

    self.viewModel.outputs.notifyDelegateCreditCardSelected
      .observeForUI()
      .observeValues { [weak self] paymentSourceId in
        guard let self = self else { return }

        self.delegate?.pledgePaymentMethodsViewController(self, didSelectCreditCard: paymentSourceId)
      }

    self.viewModel.outputs.goToAddCardViaStripeScreen
      .observeForUI()
      .observeValues { [weak self] data in
        guard let strongSelf = self else { return }

        strongSelf.goToPaymentSheet(data: data)
      }

    self.viewModel.outputs.updateAddNewCardLoading
      .observeForUI()
      .observeValues { [weak self] showLoadingIndicator in
        guard let strongSelf = self else { return }

        strongSelf.updateAddNewPaymentMethodButtonLoading(state: showLoadingIndicator)
      }
  }

  // MARK: - Configuration

  func configure(with value: PledgePaymentMethodsValue) {
    self.viewModel.inputs.configure(with: value)
  }

  // MARK: - Functions

  private func goToPaymentSheet(data: PaymentSheetSetupData) {
    let completion: (Result<PaymentSheet.FlowController, Error>) -> Void = { [weak self] result in
      guard let strongSelf = self else { return }

      switch result {
      case let .failure(error):
        strongSelf.viewModel.inputs.shouldCancelPaymentSheetAppearance(state: true)
        strongSelf.messageDisplayingDelegate?
          .pledgeViewController(strongSelf, didErrorWith: error.localizedDescription, error: error)
      case let .success(paymentSheetFlowController):
        let topViewController = strongSelf.navigationController?.topViewController

        assert(
          topViewController is NoShippingPledgeViewController ||
            topViewController is PostCampaignCheckoutViewController ||
            topViewController is NoShippingPostCampaignCheckoutViewController,
          "PledgePaymentMethodsViewController is only intended to be presented as part of a pledge flow."
        )

        strongSelf.paymentSheetFlowController = paymentSheetFlowController
        strongSelf.paymentSheetFlowController?.presentPaymentOptions(from: strongSelf) { [weak self] in
          guard let strongSelf = self else { return }

          strongSelf.confirmPaymentResult(with: data.clientSecret)
        }
        strongSelf.viewModel.inputs.stripePaymentSheetDidAppear()
      }
    }

    PaymentSheet.FlowController.create(
      setupIntentClientSecret: data.clientSecret,
      configuration: data.configuration,
      completion: completion
    )
  }

  private func confirmPaymentResult(with clientSecret: String) {
    guard self.paymentSheetFlowController?.paymentOption != nil else {
      self.viewModel.inputs.shouldCancelPaymentSheetAppearance(state: true)
      return
    }

    self.paymentSheetFlowController?.confirm(from: self) { [weak self] paymentResult in

      guard let strongSelf = self else { return }

      switch paymentResult {
      case .completed:
        // Fetch the stripe payment method ID
        STPAPIClient.shared
          .retrieveSetupIntent(withClientSecret: clientSecret) { intent, _ in
            strongSelf.viewModel.inputs.shouldCancelPaymentSheetAppearance(state: true)

            // Always try and add the card, even if the Stripe fetch failed.
            // The payment method ID is only required for late pledges.
            strongSelf.viewModel.inputs
              .paymentSheetDidAdd(
                clientSecret: clientSecret,
                paymentMethod: intent?.paymentMethodID
              )
          }
      case .canceled:
        // User cancelled intentionally so do nothing.
        strongSelf.viewModel.inputs.shouldCancelPaymentSheetAppearance(state: true)
      case let .failed(error):
        strongSelf.viewModel.inputs.shouldCancelPaymentSheetAppearance(state: true)
        strongSelf.messageDisplayingDelegate?
          .pledgeViewController(strongSelf, didErrorWith: error.localizedDescription, error: error)
      }
    }
  }

  private func updateAddNewPaymentMethodButtonLoading(state: Bool) {
    self.dataSource.updateAddNewPaymentCardLoad(state: state)

    if self.dataSource.numberOfItems(in: PaymentMethodsTableViewSection.addNewCard.rawValue) > 0 {
      self.tableView.reloadSections([PaymentMethodsTableViewSection.addNewCard.rawValue], with: .none)
    }
  }

  // MARK: - Public functions

  func cancelModalPresentation(_ hidden: Bool) {
    self.viewModel.inputs.shouldCancelPaymentSheetAppearance(state: hidden)
  }
}

// MARK: - UITableViewDelegate

extension PledgePaymentMethodsViewController: UITableViewDelegate {
  func tableView(_: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
    guard !self.dataSource.isLoadingStateCell(indexPath: indexPath) else {
      return nil
    }
    return self.viewModel.inputs.willSelectRowAtIndexPath(indexPath)
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)

    self.viewModel.inputs.didSelectRowAtIndexPath(indexPath)
  }
}
