;; VaultBridge Protocol - Blockchain Value Exchange / Transaction System

;; Core constants
(define-constant ADMIN tx-sender)
(define-constant ERR_AUTH (err u100))
(define-constant ERR_NOT_FOUND (err u101))
(define-constant ERR_PROCESSED (err u102))
(define-constant ERR_FAILED_TX (err u103))
(define-constant ERR_BAD_ID (err u104))
(define-constant ERR_BAD_VALUE (err u105))
(define-constant ERR_BAD_VENDOR (err u106))
(define-constant ERR_TIMEOUT (err u107))
(define-constant TRADE_TIMEOUT_BLOCKS u1008) 

;; Trade counter
(define-data-var trade-counter uint u0)

;; Project functions
(define-private (vendor-is-valid (vendor principal))
  (and 
    (not (is-eq vendor tx-sender))
    (not (is-eq vendor (as-contract tx-sender)))
  )
)

(define-private (trade-exists (trade-id uint))
  (<= trade-id (var-get trade-counter))
)

;; Trade data structure
(define-map TradeRegistry
  { trade-id: uint }
  {
    client: principal,
    vendor: principal,
    product-id: uint,
    amount: uint,
    status: (string-ascii 10),
    creation-time: uint,
    deadline: uint
  }
)

;; Public functions
(define-public (complete-trade (trade-id uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (vendor (get vendor trade-data))
        (amount (get amount trade-data))
        (product-id (get product-id trade-data))
      )
      (asserts! (or (is-eq tx-sender ADMIN) (is-eq tx-sender (get client trade-data))) ERR_AUTH)
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)
      (asserts! (<= block-height (get deadline trade-data)) ERR_TIMEOUT)
      (match (as-contract (stx-transfer? amount tx-sender vendor))
        success
          (begin
            (map-set TradeRegistry
              { trade-id: trade-id }
              (merge trade-data { status: "completed" })
            )
            (print {event: "trade_completed", trade-id: trade-id, vendor: vendor, product-id: product-id, amount: amount})
            (ok true)
          )
        error ERR_FAILED_TX
      )
    )
  )
)

(define-public (client-refund (trade-id uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (amount (get amount trade-data))
      )
      (asserts! (is-eq tx-sender ADMIN) ERR_AUTH)
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)
      (match (as-contract (stx-transfer? amount tx-sender client))
        success
          (begin
            (map-set TradeRegistry
              { trade-id: trade-id }
              (merge trade-data { status: "refunded" })
            )
            (print {event: "client_refunded", trade-id: trade-id, client: client, amount: amount})
            (ok true)
          )
        error ERR_FAILED_TX
      )
    )
  )
)

(define-public (client-cancel (trade-id uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (amount (get amount trade-data))
      )
      (asserts! (is-eq tx-sender client) ERR_AUTH)
      (asserts! (is-eq (get status trade-data) "pending") ERR_PROCESSED)
      (asserts! (<= block-height (get deadline trade-data)) ERR_TIMEOUT)
      (match (as-contract (stx-transfer? amount tx-sender client))
        success
          (begin
            (map-set TradeRegistry
              { trade-id: trade-id }
              (merge trade-data { status: "cancelled" })
            )
            (print {event: "trade_cancelled", trade-id: trade-id, client: client, amount: amount})
            (ok true)
          )
        error ERR_FAILED_TX
      )
    )
  )
)

(define-public (extend-deadline (trade-id uint) (added-blocks uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (asserts! (> added-blocks u0) ERR_BAD_VALUE)
    (asserts! (<= added-blocks u1440) ERR_BAD_VALUE) ;; Max extension: ~10 days
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data)) 
        (vendor (get vendor trade-data))
        (current-deadline (get deadline trade-data))
        (new-deadline (+ current-deadline added-blocks))
      )
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender vendor) (is-eq tx-sender ADMIN)) ERR_AUTH)
      (asserts! (or (is-eq (get status trade-data) "pending") (is-eq (get status trade-data) "accepted")) ERR_PROCESSED)
      (map-set TradeRegistry
        { trade-id: trade-id }
        (merge trade-data { deadline: new-deadline })
      )
      (print {event: "deadline_extended", trade-id: trade-id, requestor: tx-sender, new-deadline: new-deadline})
      (ok true)
    )
  )
)

(define-public (reclaim-expired (trade-id uint))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (amount (get amount trade-data))
        (deadline (get deadline trade-data))
      )
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender ADMIN)) ERR_AUTH)
      (asserts! (or (is-eq (get status trade-data) "pending") (is-eq (get status trade-data) "accepted")) ERR_PROCESSED)
      (asserts! (> block-height deadline) (err u108)) ;; Must be expired
      (match (as-contract (stx-transfer? amount tx-sender client))
        success
          (begin
            (map-set TradeRegistry
              { trade-id: trade-id }
              (merge trade-data { status: "expired" })
            )
            (print {event: "expired_trade_reclaimed", trade-id: trade-id, client: client, amount: amount})
            (ok true)
          )
        error ERR_FAILED_TX
      )
    )
  )
)

(define-public (raise-dispute (trade-id uint) (reason (string-ascii 50)))
  (begin
    (asserts! (trade-exists trade-id) ERR_BAD_ID)
    (let
      (
        (trade-data (unwrap! (map-get? TradeRegistry { trade-id: trade-id }) ERR_NOT_FOUND))
        (client (get client trade-data))
        (vendor (get vendor trade-data))
      )
      (asserts! (or (is-eq tx-sender client) (is-eq tx-sender vendor)) ERR_AUTH)
      (asserts! (or (is-eq (get status trade-data) "pending") (is-eq (get status trade-data) "accepted")) ERR_PROCESSED)
      (asserts! (<= block-height (get deadline trade-data)) ERR_TIMEOUT)
      (map-set TradeRegistry
        { trade-id: trade-id }
        (merge trade-data { status: "disputed" })
      )
      (print {event: "dispute_raised", trade-id: trade-id, party: tx-sender, reason: reason})
      (ok true)
    )
  )
)

