;; soundtrek-marketplace.clar
;; Facilitates the monetization and trading of audio recordings as NFTs in the SoundTrek platform.
;; This contract handles marketplace functionality including listing, buying, selling, and auctioning
;; of audio NFTs, as well as implementing tipping mechanisms and royalty distribution.

;; ==================
;; Constants
;; ==================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-LISTING-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-LISTED (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-INVALID-PRICE (err u104))
(define-constant ERR-NOT-OWNER (err u105))
(define-constant ERR-AUCTION-NOT-FOUND (err u106))
(define-constant ERR-AUCTION-ENDED (err u107))
(define-constant ERR-INVALID-BID (err u108))
(define-constant ERR-AUCTION-ACTIVE (err u109))
(define-constant ERR-NFT-NOT-OWNED (err u110))
(define-constant ERR-ROYALTY-TOO-HIGH (err u111))
(define-constant ERR-COLLECTION-NOT-FOUND (err u112))
(define-constant ERR-SUBSCRIPTION-EXPIRED (err u113))

;; Configuration constants
(define-constant MARKETPLACE-FEE-PERCENT u5)  ;; 5% marketplace fee
(define-constant MAX-ROYALTY-PERCENT u30)     ;; Maximum royalty percentage (30%)
(define-constant MIN-LISTING-PRICE u1000)     ;; Minimum listing price (1000 ustx)
(define-constant MIN-BID_INCREMENT_PERCENT u5) ;; Minimum bid increment (5%)
(define-constant CONTRACT-OWNER tx-sender)    ;; Contract owner

;; ==================
;; Data Maps
;; ==================

;; Tracks all marketplace listings
(define-map listings
  { nft-id: uint }
  {
    owner: principal,
    price: uint,
    listed-at: uint,
    royalty-percent: uint,
    creator: principal
  }
)

;; Tracks active auctions
(define-map auctions
  { nft-id: uint }
  {
    owner: principal,
    reserve-price: uint,
    highest-bid: uint,
    highest-bidder: (optional principal),
    start-block: uint,
    end-block: uint,
    royalty-percent: uint,
    creator: principal
  }
)

;; Tracks bid amounts for each bidder in an auction
(define-map auction-bids
  { nft-id: uint, bidder: principal }
  { bid-amount: uint }
)

;; Tracks NFT ownership history
(define-map ownership-history
  { nft-id: uint }
  { history: (list 10 { owner: principal, acquired-at: uint }) }
)

;; Tracks collections of NFTs grouped by creator
(define-map collections
  { collection-id: uint }
  {
    creator: principal,
    name: (string-ascii 50),
    subscription-price: uint,
    description: (string-ascii 200)
  }
)

;; Maps NFTs to their collection
(define-map nft-collection-map
  { nft-id: uint }
  { collection-id: uint }
)

;; Tracks user subscriptions to collections
(define-map subscriptions
  { user: principal, collection-id: uint }
  {
    expires-at-block: uint,
    subscription-price: uint
  }
)

;; ==================
;; Data Variables
;; ==================

;; Counter for collection IDs
(define-data-var next-collection-id uint u1)

;; ==================
;; Private Functions
;; ==================

;; Calculate the marketplace fee for a given amount
(define-private (calculate-marketplace-fee (amount uint))
  (/ (* amount MARKETPLACE-FEE-PERCENT) u100)
)

;; Calculate royalty amount for a given sale price and royalty percentage
(define-private (calculate-royalty (price uint) (royalty-percent uint))
  (/ (* price royalty-percent) u100)
)

;; Add an entry to the ownership history of an NFT
(define-private (add-to-history (nft-id uint) (new-owner principal))
  (let (
    (current-history (default-to { history: (list) } (map-get? ownership-history { nft-id: nft-id })))
    (new-entry { owner: new-owner, acquired-at: block-height })
    (updated-history (unwrap-panic (as-max-len? (append (get history current-history) new-entry) u10)))
  )
    (map-set ownership-history { nft-id: nft-id } { history: updated-history })
  )
)

;; Verify if caller owns the NFT (implemented as a mock - would interact with NFT contract)
(define-private (owns-nft? (nft-id uint) (owner principal))
  ;; In production, this would check the actual NFT contract
  ;; Mock implementation for demonstration
  (let (
    (listing (map-get? listings { nft-id: nft-id }))
  )
    (and 
      (is-some listing)
      (is-eq owner (get owner (unwrap! listing false)))
    )
  )
)

;; Process payment distribution including royalties and marketplace fee
(define-private (process-payment (nft-id uint) (price uint))
  (let (
    (listing (unwrap! (map-get? listings { nft-id: nft-id }) ERR-LISTING-NOT-FOUND))
    (owner (get owner listing))
    (creator (get creator listing))
    (royalty-percent (get royalty-percent listing))
    (royalty-amount (calculate-royalty price royalty-percent))
    (marketplace-fee (calculate-marketplace-fee price))
    (seller-amount (- price (+ royalty-amount marketplace-fee)))
  )
    ;; Send royalty to creator
    (if (> royalty-amount u0)
      (try! (stx-transfer? royalty-amount tx-sender creator))
      true
    )
    
    ;; Send marketplace fee to contract owner
    (try! (stx-transfer? marketplace-fee tx-sender CONTRACT-OWNER))
    
    ;; Send remaining amount to seller
    (try! (stx-transfer? seller-amount tx-sender owner))
    
    (ok true)
  )
)

;; ==================
;; Read-Only Functions
;; ==================

;; Get listing details for an NFT
(define-read-only (get-listing (nft-id uint))
  (map-get? listings { nft-id: nft-id })
)

;; Get auction details for an NFT
(define-read-only (get-auction (nft-id uint))
  (map-get? auctions { nft-id: nft-id })
)

;; Get a user's bid in an auction
(define-read-only (get-bid (nft-id uint) (bidder principal))
  (map-get? auction-bids { nft-id: nft-id, bidder: bidder })
)

;; Get ownership history for an NFT
(define-read-only (get-ownership-history (nft-id uint))
  (map-get? ownership-history { nft-id: nft-id })
)

;; Get collection details
(define-read-only (get-collection (collection-id uint))
  (map-get? collections { collection-id: collection-id })
)

;; Check if a user has an active subscription to a collection
(define-read-only (has-subscription? (user principal) (collection-id uint))
  (let (
    (subscription (map-get? subscriptions { user: user, collection-id: collection-id }))
  )
    (if (is-some subscription)
      (> (get expires-at-block (unwrap! subscription false)) block-height)
      false
    )
  )
)

;; ==================
;; Public Functions
;; ==================

;; List an NFT for sale in the marketplace
(define-public (list-nft (nft-id uint) (price uint) (royalty-percent uint))
  (let (
    (caller tx-sender)
  )
    ;; Perform validations
    (asserts! (> price MIN-LISTING-PRICE) ERR-INVALID-PRICE)
    (asserts! (<= royalty-percent MAX-ROYALTY-PERCENT) ERR-ROYALTY-TOO-HIGH)
    (asserts! (owns-nft? nft-id caller) ERR-NOT-OWNER)
    (asserts! (is-none (map-get? listings { nft-id: nft-id })) ERR-ALREADY-LISTED)
    
    ;; Create the listing
    (map-set listings
      { nft-id: nft-id }
      {
        owner: caller,
        price: price,
        listed-at: block-height,
        royalty-percent: royalty-percent,
        creator: caller
      }
    )
    
    ;; Initialize ownership history if it doesn't exist
    (if (is-none (map-get? ownership-history { nft-id: nft-id }))
      (map-set ownership-history 
        { nft-id: nft-id } 
        { history: (list { owner: caller, acquired-at: block-height }) }
      )
      true
    )
    
    (ok true)
  )
)

;; Cancel a listing
(define-public (cancel-listing (nft-id uint))
  (let (
    (listing (unwrap! (map-get? listings { nft-id: nft-id }) ERR-LISTING-NOT-FOUND))
  )
    ;; Verify caller is the owner
    (asserts! (is-eq tx-sender (get owner listing)) ERR-NOT-AUTHORIZED)
    
    ;; Remove the listing
    (map-delete listings { nft-id: nft-id })
    
    (ok true)
  )
)

;; Buy an NFT from a listing
(define-public (buy-nft (nft-id uint))
  (let (
    (listing (unwrap! (map-get? listings { nft-id: nft-id }) ERR-LISTING-NOT-FOUND))
    (price (get price listing))
    (owner (get owner listing))
    (buyer tx-sender)
  )
    ;; Ensure buyer is not the owner
    (asserts! (not (is-eq buyer owner)) ERR-NOT-AUTHORIZED)
    
    ;; Process payment
    (try! (process-payment nft-id price))
    
    ;; Update ownership history
    (add-to-history nft-id buyer)
    
    ;; Remove the listing
    (map-delete listings { nft-id: nft-id })
    
    ;; In production, would call NFT contract to transfer ownership
    ;; For this example, we'll just return success
    (ok true)
  )
)

;; Create an auction for an NFT
(define-public (create-auction (nft-id uint) (reserve-price uint) (duration-blocks uint) (royalty-percent uint))
  (let (
    (caller tx-sender)
    (end-block (+ block-height duration-blocks))
  )
    ;; Perform validations
    (asserts! (> reserve-price MIN-LISTING-PRICE) ERR-INVALID-PRICE)
    (asserts! (<= royalty-percent MAX-ROYALTY-PERCENT) ERR-ROYALTY-TOO-HIGH)
    (asserts! (owns-nft? nft-id caller) ERR-NOT-OWNER)
    (asserts! (is-none (map-get? auctions { nft-id: nft-id })) ERR-ALREADY-LISTED)
    
    ;; Create the auction
    (map-set auctions
      { nft-id: nft-id }
      {
        owner: caller,
        reserve-price: reserve-price,
        highest-bid: u0,
        highest-bidder: none,
        start-block: block-height,
        end-block: end-block,
        royalty-percent: royalty-percent,
        creator: caller
      }
    )
    
    (ok true)
  )
)

;; Place a bid in an auction
(define-public (place-bid (nft-id uint) (bid-amount uint))
  (let (
    (auction (unwrap! (map-get? auctions { nft-id: nft-id }) ERR-AUCTION-NOT-FOUND))
    (bidder tx-sender)
    (current-highest-bid (get highest-bid auction))
    (min-bid (+ current-highest-bid (/ (* current-highest-bid MIN-BID_INCREMENT_PERCENT) u100)))
  )
    ;; Validations
    (asserts! (< block-height (get end-block auction)) ERR-AUCTION-ENDED)
    (asserts! (not (is-eq bidder (get owner auction))) ERR-NOT-AUTHORIZED)
    (asserts! (or (= current-highest-bid u0) (> bid-amount min-bid)) ERR-INVALID-BID)
    (asserts! (>= bid-amount (get reserve-price auction)) ERR-INVALID-BID)
    
    ;; Transfer STX to contract (in actual implementation, would use escrow)
    (try! (stx-transfer? bid-amount bidder CONTRACT-OWNER))
    
    ;; Refund previous highest bidder if exists
    (match (get highest-bidder auction)
      prev-bidder (stx-transfer? current-highest-bid CONTRACT-OWNER prev-bidder)
      true
    )
    
    ;; Update auction with new highest bid
    (map-set auctions
      { nft-id: nft-id }
      (merge auction {
        highest-bid: bid-amount,
        highest-bidder: (some bidder)
      })
    )
    
    ;; Record the bid
    (map-set auction-bids
      { nft-id: nft-id, bidder: bidder }
      { bid-amount: bid-amount }
    )
    
    (ok true)
  )
)

;; Finalize an auction after it has ended
(define-public (finalize-auction (nft-id uint))
  (let (
    (auction (unwrap! (map-get? auctions { nft-id: nft-id }) ERR-AUCTION-NOT-FOUND))
    (caller tx-sender)
  )
    ;; Validate auction can be finalized
    (asserts! (>= block-height (get end-block auction)) ERR-AUCTION-ACTIVE)
    (asserts! (or (is-eq caller (get owner auction)) (is-eq caller CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)
    
    ;; Check if there was a winning bid
    (match (get highest-bidder auction)
      winner (begin
        ;; Process payment distribution
        (let (
          (bid-amount (get highest-bid auction))
          (royalty-percent (get royalty-percent auction))
          (creator (get creator auction))
          (owner (get owner auction))
          (royalty-amount (calculate-royalty bid-amount royalty-percent))
          (marketplace-fee (calculate-marketplace-fee bid-amount))
          (seller-amount (- bid-amount (+ royalty-amount marketplace-fee)))
        )
          ;; Transfer royalty to creator
          (if (> royalty-amount u0)
            (try! (stx-transfer? royalty-amount CONTRACT-OWNER creator))
            true
          )
          
          ;; Send marketplace fee (already in contract wallet)
          
          ;; Transfer remainder to seller
          (try! (stx-transfer? seller-amount CONTRACT-OWNER owner))
          
          ;; Update ownership history
          (add-to-history nft-id winner)
          
          ;; In production, would call NFT contract to transfer ownership
        )
        
        (ok true)
      )
      
      ;; No winner, auction failed
      (begin
        (ok false)
      )
    )
    
    ;; Clean up auction data
    (map-delete auctions { nft-id: nft-id })
    
    (ok true)
  )
)

;; Create a collection of NFTs
(define-public (create-collection (name (string-ascii 50)) (description (string-ascii 200)) (subscription-price uint))
  (let (
    (creator tx-sender)
    (collection-id (var-get next-collection-id))
  )
    ;; Create the collection
    (map-set collections
      { collection-id: collection-id }
      {
        creator: creator,
        name: name,
        subscription-price: subscription-price,
        description: description
      }
    )
    
    ;; Increment the collection ID counter
    (var-set next-collection-id (+ collection-id u1))
    
    (ok collection-id)
  )
)

;; Add an NFT to a collection
(define-public (add-to-collection (nft-id uint) (collection-id uint))
  (let (
    (caller tx-sender)
    (collection (unwrap! (map-get? collections { collection-id: collection-id }) ERR-COLLECTION-NOT-FOUND))
  )
    ;; Verify caller is the collection creator
    (asserts! (is-eq caller (get creator collection)) ERR-NOT-AUTHORIZED)
    
    ;; Verify caller owns the NFT
    (asserts! (owns-nft? nft-id caller) ERR-NOT-OWNER)
    
    ;; Add NFT to collection
    (map-set nft-collection-map
      { nft-id: nft-id }
      { collection-id: collection-id }
    )
    
    (ok true)
  )
)

;; Subscribe to a collection
(define-public (subscribe-to-collection (collection-id uint) (duration-blocks uint))
  (let (
    (collection (unwrap! (map-get? collections { collection-id: collection-id }) ERR-COLLECTION-NOT-FOUND))
    (subscription-price (get subscription-price collection))
    (total-price (* subscription-price duration-blocks))
    (subscriber tx-sender)
    (expires-at (+ block-height duration-blocks))
  )
    ;; Process payment
    (try! (stx-transfer? total-price subscriber (get creator collection)))
    
    ;; Create or update subscription
    (map-set subscriptions
      { user: subscriber, collection-id: collection-id }
      {
        expires-at-block: expires-at,
        subscription-price: subscription-price
      }
    )
    
    (ok true)
  )
)

;; Send a tip to a content creator
(define-public (tip-creator (creator principal) (amount uint))
  (let (
    (tipper tx-sender)
  )
    ;; Validate tipper is not tipping themselves
    (asserts! (not (is-eq tipper creator)) ERR-NOT-AUTHORIZED)
    
    ;; Process the tip
    (try! (stx-transfer? amount tipper creator))
    
    (ok true)
  )
)

;; Update listing price
(define-public (update-listing-price (nft-id uint) (new-price uint))
  (let (
    (listing (unwrap! (map-get? listings { nft-id: nft-id }) ERR-LISTING-NOT-FOUND))
    (caller tx-sender)
  )
    ;; Validate caller is the owner
    (asserts! (is-eq caller (get owner listing)) ERR-NOT-AUTHORIZED)
    (asserts! (> new-price MIN-LISTING-PRICE) ERR-INVALID-PRICE)
    
    ;; Update the listing
    (map-set listings
      { nft-id: nft-id }
      (merge listing { price: new-price })
    )
    
    (ok true)
  )
)