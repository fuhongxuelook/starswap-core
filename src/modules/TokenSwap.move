// TODO: replace the address with admin address
address 0x07fa08a855753f0ff7292fdcbe871216 {

/// Token Swap
module TokenSwap {
    use 0x1::Token;
    use 0x1::Signer;
    use 0x1::Math;
    use 0x1::Compare;
    use 0x1::BCS;

    struct LiquidityToken<X, Y> has key, store { }

    struct LiquidityTokenCapability<X, Y> has key, store {
        mint: Token::MintCapability<LiquidityToken<X, Y>>,
        burn: Token::BurnCapability<LiquidityToken<X, Y>>,
    }

    struct TokenPair<X, Y> has key, store  {
        token_x_reserve: Token::Token<X>,
        token_y_reserve: Token::Token<Y>,
        last_block_timestamp: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        last_k: u128,
    }

    const ERROR_SWAP_INVALID_TOKEN_PAIR: u64 = 2000;
    const ERROR_SWAP_INVALID_PARAMETER: u64 = 2001;
    const ERROR_SWAP_TOKEN_INSUFFICIENT: u64 = 2002;
    const ERROR_SWAP_DUPLICATE_TOKEN: u64 = 2003;
    const ERROR_SWAP_BURN_CALC_INVALID: u64 = 2004;
    const ERROR_SWAP_SWAPOUT_CALC_INVALID: u64 = 2005;
    const ERROR_SWAP_PRIVILEGE_INSUFFICIENT: u64 = 2006;
    const ERROR_SWAP_ADDLIQUIDITY_INVALID: u64 = 2007;


    // TODO: check X,Y is token.
    // for now, only admin can register token pair
    public fun register_swap_pair<X: store, Y: store>(signer: &signer) {
        let order = compare_token<X, Y>();
        assert(order != 0, ERROR_SWAP_INVALID_TOKEN_PAIR);
        assert_admin(signer);
        let token_pair = make_token_pair<X, Y>();
        move_to(signer, token_pair);
        register_liquidity_token<X, Y>(signer);
    }

    fun register_liquidity_token<X: store, Y: store>(signer: &signer) {
        assert_admin(signer);
        Token::register_token<LiquidityToken<X, Y>>(signer, 18);
        let mint_capability = Token::remove_mint_capability<LiquidityToken<X, Y>>(signer);
        let burn_capability = Token::remove_burn_capability<LiquidityToken<X, Y>>(signer);
        move_to(signer, LiquidityTokenCapability { mint: mint_capability, burn: burn_capability });
    }

    fun make_token_pair<X: store, Y: store>(): TokenPair<X, Y> {
        // TODO: assert X, Y is token
        TokenPair<X, Y> {
            token_x_reserve: Token::zero<X>(),
            token_y_reserve: Token::zero<Y>(),
            last_block_timestamp: 0,
            last_price_x_cumulative: 0,
            last_price_y_cumulative: 0,
            last_k: 0,
        }
    }

    /// Liquidity Provider's methods
    /// type args, X, Y should be sorted.
    public fun mint<X: store, Y: store>(
        x: Token::Token<X>,
        y: Token::Token<Y>,
    ): Token::Token<LiquidityToken<X, Y>> acquires TokenPair, LiquidityTokenCapability {
        let total_supply: u128 = Token::market_cap<LiquidityToken<X, Y>>();
        let x_value = Token::value<X>(&x);
        let y_value = Token::value<Y>(&y);
        let liquidity = if (total_supply == 0) {
            // 1000 is the MINIMUM_LIQUIDITY
            (Math::sqrt((x_value as u128) * (y_value as u128)) as u128) - 1000
        } else {
            let token_pair = borrow_global<TokenPair<X, Y>>(admin_address());
            let x_reserve = Token::value(&token_pair.token_x_reserve);
            let y_reserve = Token::value(&token_pair.token_y_reserve);
            let x_liquidity = x_value * total_supply / x_reserve;
            let y_liquidity = y_value * total_supply / y_reserve;
            // use smaller one.
            if (x_liquidity < y_liquidity) {
                x_liquidity
            } else {
                y_liquidity
            }
        };
        assert(liquidity > 0, ERROR_SWAP_ADDLIQUIDITY_INVALID);
        let token_pair = borrow_global_mut<TokenPair<X, Y>>(admin_address());
        Token::deposit(&mut token_pair.token_x_reserve, x);
        Token::deposit(&mut token_pair.token_y_reserve, y);
        let liquidity_cap = borrow_global<LiquidityTokenCapability<X, Y>>(admin_address());
        let mint_token = Token::mint_with_capability(&liquidity_cap.mint, liquidity);
        mint_token
    }

    public fun burn<X: store, Y: store>(
        to_burn: Token::Token<LiquidityToken<X, Y>>,
    ): (Token::Token<X>, Token::Token<Y>) acquires TokenPair, LiquidityTokenCapability {
        let to_burn_value = (Token::value(&to_burn) as u128);
        let token_pair = borrow_global_mut<TokenPair<X, Y>>(admin_address());
        let x_reserve = (Token::value(&token_pair.token_x_reserve) as u128);
        let y_reserve = (Token::value(&token_pair.token_y_reserve) as u128);
        let total_supply = Token::market_cap<LiquidityToken<X, Y>>();
        let x = to_burn_value * x_reserve / total_supply;
        let y = to_burn_value * y_reserve / total_supply;
        assert(x > 0 && y > 0, ERROR_SWAP_BURN_CALC_INVALID);
        burn_liquidity(to_burn);
        let x_token = Token::withdraw(&mut token_pair.token_x_reserve, x);
        let y_token = Token::withdraw(&mut token_pair.token_y_reserve, y);
        (x_token, y_token)
    }

    fun burn_liquidity<X: store, Y: store>(to_burn: Token::Token<LiquidityToken<X, Y>>)
    acquires LiquidityTokenCapability {
        let liquidity_cap = borrow_global<LiquidityTokenCapability<X, Y>>(admin_address());
        Token::burn_with_capability<LiquidityToken<X, Y>>(&liquidity_cap.burn, to_burn);
    }

    //// User methods ////////

    /// Get reserves of a token pair.
    /// The order of type args should be sorted.
    public fun get_reserves<X: store, Y: store>(): (u128, u128) acquires TokenPair {
        let token_pair = borrow_global<TokenPair<X, Y>>(admin_address());
        let x_reserve = Token::value(&token_pair.token_x_reserve);
        let y_reserve = Token::value(&token_pair.token_y_reserve);
        (x_reserve, y_reserve)
    }

    public fun swap<X: store, Y: store>(
        x_in: Token::Token<X>,
        y_out: u128,
        y_in: Token::Token<Y>,
        x_out: u128,
    ): (Token::Token<X>, Token::Token<Y>) acquires TokenPair {
        let x_in_value = Token::value(&x_in);
        let y_in_value = Token::value(&y_in);
        assert(x_in_value > 0 || y_in_value > 0, ERROR_SWAP_TOKEN_INSUFFICIENT);
        let (x_reserve, y_reserve) = get_reserves<X, Y>();
        let token_pair = borrow_global_mut<TokenPair<X, Y>>(admin_address());
        Token::deposit(&mut token_pair.token_x_reserve, x_in);
        Token::deposit(&mut token_pair.token_y_reserve, y_in);
        let x_swapped = Token::withdraw(&mut token_pair.token_x_reserve, x_out);
        let y_swapped = Token::withdraw(&mut token_pair.token_y_reserve, y_out);
            {
                let x_reserve_new = Token::value(&token_pair.token_x_reserve);
                let y_reserve_new = Token::value(&token_pair.token_y_reserve);
                let x_adjusted = x_reserve_new * 1000 - x_in_value * 3;
                let y_adjusted = y_reserve_new * 1000 - y_in_value * 3;
                assert(x_adjusted * y_adjusted >= x_reserve * y_reserve * 1000000, ERROR_SWAP_SWAPOUT_CALC_INVALID);
            };
        (x_swapped, y_swapped)
    }

    /// Caller should call this function to determine the order of A, B
    public fun compare_token<A: store, B: store>(): u8 {
        let a_bytes = BCS::to_bytes<Token::TokenCode>(&Token::token_code<A>());
        let b_bytes = BCS::to_bytes<Token::TokenCode>(&Token::token_code<B>());
        let ret : u8 = Compare::cmp_bcs_bytes(&a_bytes, &b_bytes);
        ret
    }

    fun assert_admin(signer: &signer) {
        assert(Signer::address_of(signer) == admin_address(), ERROR_SWAP_PRIVILEGE_INSUFFICIENT);
    }

    fun admin_address(): address {
        @0x07fa08a855753f0ff7292fdcbe871216
        // 0x1
    }
}
}