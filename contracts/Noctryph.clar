;; Noctryph - Soulbound Token Identity System
;; A metaverse passport system issuing soulbound tokens for digital identity and reputation

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u401))
(define-constant ERR_ALREADY_EXISTS (err u409))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_INVALID_INPUT (err u400))
(define-constant ERR_TRANSFER_NOT_ALLOWED (err u403))
(define-constant ERR_INSUFFICIENT_BALANCE (err u402))
(define-constant MAX_TOKEN_ID u1000000)
(define-constant MAX_CREDENTIAL_ID u10000)

;; Data Variables
(define-data-var next-token-id uint u1)
(define-data-var contract-uri (string-utf8 256) u"https://noctryph.io/metadata/")

;; Data Maps
(define-map tokens
  { token-id: uint }
  {
    owner: principal,
    metadata-uri: (string-utf8 256),
    badge-type: (string-ascii 32),
    mint-block: uint,
    is-active: bool
  }
)

(define-map user-profiles
  { user: principal }
  {
    total-badges: uint,
    reputation-score: uint,
    last-activity: uint,
    is-verified: bool
  }
)

(define-map credentials
  { token-id: uint, credential-id: uint }
  {
    credential-type: (string-ascii 32),
    description: (string-utf8 256),
    issuer: principal,
    verified-at: uint,
    is-valid: bool
  }
)

(define-map user-credential-count
  { user: principal }
  { count: uint }
)

(define-map authorized-verifiers
  { verifier: principal }
  { is-authorized: bool }
)

;; Simple mapping to track user badge types directly - eliminates need for recursive search
(define-map user-badge-types
  { user: principal, badge-type: (string-ascii 32) }
  { token-id: uint, is-active: bool }
)

;; ALL PRIVATE FUNCTIONS FIRST
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT_OWNER)
)

(define-private (is-authorized-verifier (verifier principal))
  (default-to false (get is-authorized (map-get? authorized-verifiers { verifier: verifier })))
)

(define-private (validate-string-input (input (string-utf8 256)))
  (and 
    (> (len input) u0)
    (<= (len input) u256)
  )
)

(define-private (validate-ascii-input (input (string-ascii 32)))
  (and 
    (> (len input) u0)
    (<= (len input) u32)
  )
)

(define-private (validate-token-id (token-id uint))
  (let ((current-next-id (var-get next-token-id)))
    (and
      (> token-id u0)
      (<= token-id MAX_TOKEN_ID)
      (< token-id current-next-id)
      ;; Additional safety: ensure token actually exists
      (is-some (map-get? tokens { token-id: token-id }))
    )
  )
)

(define-private (validate-credential-id (credential-id uint))
  (and
    (> credential-id u0)
    (<= credential-id MAX_CREDENTIAL_ID)
  )
)

(define-private (validate-principal (user principal))
  ;; Check that principal is not zero address equivalent
  (not (is-eq user 'SP000000000000000000002Q6VF78))
)

(define-private (user-has-badge-type (recipient principal) (badge-type (string-ascii 32)))
  (match (map-get? user-badge-types { user: recipient, badge-type: badge-type })
    badge-entry
    (get is-active badge-entry)
    false
  )
)

(define-private (get-user-badge-token-id (user principal) (badge-type (string-ascii 32)))
  (match (map-get? user-badge-types { user: user, badge-type: badge-type })
    badge-entry
    (if (get is-active badge-entry)
      (some (get token-id badge-entry))
      none
    )
    none
  )
)

;; PUBLIC FUNCTIONS
(define-public (mint-identity-badge (recipient principal) (badge-type (string-ascii 32)) (metadata-uri (string-utf8 256)))
  (let
    (
      (token-id (var-get next-token-id))
      (current-block stacks-block-height)
    )
    (asserts! (is-authorized-verifier tx-sender) ERR_NOT_AUTHORIZED)
    (asserts! (validate-principal recipient) ERR_INVALID_INPUT)
    (asserts! (validate-ascii-input badge-type) ERR_INVALID_INPUT)
    (asserts! (validate-string-input metadata-uri) ERR_INVALID_INPUT)
    (asserts! (<= token-id MAX_TOKEN_ID) ERR_INVALID_INPUT)
    
    ;; Check if user already has this badge type
    (asserts! (not (user-has-badge-type recipient badge-type)) ERR_ALREADY_EXISTS)
    
    ;; Mint the token
    (map-set tokens
      { token-id: token-id }
      {
        owner: recipient,
        metadata-uri: metadata-uri,
        badge-type: badge-type,
        mint-block: current-block,
        is-active: true
      }
    )
    
    ;; Add to user badge types mapping
    (map-set user-badge-types
      { user: recipient, badge-type: badge-type }
      { token-id: token-id, is-active: true }
    )
    
    ;; Update user profile
    (match (map-get? user-profiles { user: recipient })
      existing-profile
      (map-set user-profiles
        { user: recipient }
        (merge existing-profile { 
          total-badges: (+ (get total-badges existing-profile) u1),
          last-activity: current-block
        })
      )
      ;; Create new profile
      (map-set user-profiles
        { user: recipient }
        {
          total-badges: u1,
          reputation-score: u100,
          last-activity: current-block,
          is-verified: false
        }
      )
    )
    
    ;; Increment token counter
    (var-set next-token-id (+ token-id u1))
    
    (ok token-id)
  )
)

(define-public (add-credential (token-id uint) (credential-type (string-ascii 32)) (description (string-utf8 256)))
  (let
    (
      (token-data (unwrap! (map-get? tokens { token-id: token-id }) ERR_NOT_FOUND))
      (token-owner (get owner token-data))
      (current-block stacks-block-height)
      (credential-count (default-to u0 (get count (map-get? user-credential-count { user: token-owner }))))
      (credential-id (+ credential-count u1))
    )
    (asserts! (validate-token-id token-id) ERR_INVALID_INPUT)
    (asserts! (validate-credential-id credential-id) ERR_INVALID_INPUT)
    (asserts! (or (is-eq tx-sender token-owner) (is-authorized-verifier tx-sender)) ERR_NOT_AUTHORIZED)
    (asserts! (validate-ascii-input credential-type) ERR_INVALID_INPUT)
    (asserts! (validate-string-input description) ERR_INVALID_INPUT)
    (asserts! (get is-active token-data) ERR_NOT_FOUND)
    
    ;; Add credential
    (map-set credentials
      { token-id: token-id, credential-id: credential-id }
      {
        credential-type: credential-type,
        description: description,
        issuer: tx-sender,
        verified-at: current-block,
        is-valid: true
      }
    )
    
    ;; Update credential count
    (map-set user-credential-count
      { user: token-owner }
      { count: credential-id }
    )
    
    ;; Update reputation score
    (unwrap! (match (map-get? user-profiles { user: token-owner })
      existing-profile
      (begin
        (map-set user-profiles
          { user: token-owner }
          (merge existing-profile { 
            reputation-score: (+ (get reputation-score existing-profile) u10),
            last-activity: current-block
          })
        )
        (ok true)
      )
      ERR_NOT_FOUND
    ) ERR_NOT_FOUND)
    
    (ok credential-id)
  )
)

(define-public (verify-user (user principal))
  (let
    (
      (profile (unwrap! (map-get? user-profiles { user: user }) ERR_NOT_FOUND))
      (current-block stacks-block-height)
    )
    (asserts! (is-authorized-verifier tx-sender) ERR_NOT_AUTHORIZED)
    (asserts! (validate-principal user) ERR_INVALID_INPUT)
    
    (map-set user-profiles
      { user: user }
      (merge profile { 
        is-verified: true,
        reputation-score: (+ (get reputation-score profile) u50),
        last-activity: current-block
      })
    )
    
    (ok true)
  )
)

(define-public (authorize-verifier (verifier principal))
  (begin
    (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
    (asserts! (validate-principal verifier) ERR_INVALID_INPUT)
    
    (map-set authorized-verifiers
      { verifier: verifier }
      { is-authorized: true }
    )
    
    (ok true)
  )
)

(define-public (revoke-verifier (verifier principal))
  (begin
    (asserts! (is-contract-owner) ERR_NOT_AUTHORIZED)
    (asserts! (validate-principal verifier) ERR_INVALID_INPUT)
    
    (map-set authorized-verifiers
      { verifier: verifier }
      { is-authorized: false }
    )
    
    (ok true)
  )
)

(define-public (deactivate-token (token-id uint))
  (let
    (
      (token-data (unwrap! (map-get? tokens { token-id: token-id }) ERR_NOT_FOUND))
      (token-owner (get owner token-data))
      (badge-type (get badge-type token-data))
    )
    (asserts! (validate-token-id token-id) ERR_INVALID_INPUT)
    (asserts! (or (is-eq tx-sender token-owner) (is-contract-owner)) ERR_NOT_AUTHORIZED)
    
    ;; Deactivate token
    (map-set tokens
      { token-id: token-id }
      (merge token-data { is-active: false })
    )
    
    ;; Deactivate in user badge types mapping
    (map-set user-badge-types
      { user: token-owner, badge-type: badge-type }
      { token-id: token-id, is-active: false }
    )
    
    (ok true)
  )
)

(define-public (transfer (token-id uint) (sender principal) (recipient principal))
  ERR_TRANSFER_NOT_ALLOWED
)

;; READ-ONLY FUNCTIONS - FIXED VALIDATION ISSUES
(define-read-only (get-token-metadata (token-id uint))
  (if (and (> token-id u0) (<= token-id MAX_TOKEN_ID))
    (map-get? tokens { token-id: token-id })
    none
  )
)

(define-read-only (get-user-profile (user principal))
  (if (validate-principal user)
    (map-get? user-profiles { user: user })
    none
  )
)

(define-read-only (get-credential (token-id uint) (credential-id uint))
  (if (and 
        (> token-id u0) 
        (<= token-id MAX_TOKEN_ID)
        (> credential-id u0) 
        (<= credential-id MAX_CREDENTIAL_ID))
    (map-get? credentials { token-id: token-id, credential-id: credential-id })
    none
  )
)

(define-read-only (get-user-badge-by-type (user principal) (badge-type (string-ascii 32)))
  (if (and (validate-principal user) (validate-ascii-input badge-type))
    (get-user-badge-token-id user badge-type)
    none
  )
)

(define-read-only (user-has-badge (user principal) (badge-type (string-ascii 32)))
  (if (and (validate-principal user) (validate-ascii-input badge-type))
    (user-has-badge-type user badge-type)
    false
  )
)

(define-read-only (get-reputation-score (user principal))
  (if (validate-principal user)
    (match (map-get? user-profiles { user: user })
      profile
      (some (get reputation-score profile))
      none
    )
    none
  )
)

(define-read-only (is-verified-user (user principal))
  (if (validate-principal user)
    (match (map-get? user-profiles { user: user })
      profile
      (get is-verified profile)
      false
    )
    false
  )
)

(define-read-only (get-total-supply)
  (let ((current-next-id (var-get next-token-id)))
    (if (> current-next-id u1)
      (- current-next-id u1)
      u0
    )
  )
)

(define-read-only (get-contract-uri)
  (var-get contract-uri)
)

(define-read-only (is-authorized-verifier-check (verifier principal))
  (if (validate-principal verifier)
    (is-authorized-verifier verifier)
    false
  )
)

(define-read-only (get-last-token-id)
  (let ((current-next-id (var-get next-token-id)))
    (if (> current-next-id u1)
      (ok (- current-next-id u1))
      (ok u0)
    )
  )
)

(define-read-only (get-token-uri (token-id uint))
  (if (and (> token-id u0) (<= token-id MAX_TOKEN_ID))
    (match (map-get? tokens { token-id: token-id })
      token-data
      (ok (some (get metadata-uri token-data)))
      ERR_NOT_FOUND
    )
    ERR_INVALID_INPUT
  )
)

(define-read-only (get-owner (token-id uint))
  (if (and (> token-id u0) (<= token-id MAX_TOKEN_ID))
    (match (map-get? tokens { token-id: token-id })
      token-data
      (ok (some (get owner token-data)))
      ERR_NOT_FOUND
    )
    ERR_INVALID_INPUT
  )
)

(define-read-only (get-balance (account principal))
  (if (validate-principal account)
    (match (map-get? user-profiles { user: account })
      profile
      (ok (get total-badges profile))
      (ok u0)
    )
    ERR_INVALID_INPUT
  )
)

;; Initialize contract
(map-set authorized-verifiers
  { verifier: CONTRACT_OWNER }
  { is-authorized: true }
)