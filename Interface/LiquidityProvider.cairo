# LP contract
# all numbers passed into contract must be Math64x61 type

# imports
%lang starknet
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_nn, assert_nn_le
from starkware.starknet.common.syscalls import get_caller_address
from starkware.starknet.common.syscalls import get_block_timestamp
from InterfaceAll import (TrustedAddy, CZCore, Settings)
from Math.Math64x61 import (Math64x61_mul, Math64x61_div, Math64x61_sub, Math64x61_add, Math64x61_pow)

##################################################################
# constants 
const Math64x61_FRACT_PART = 2 ** 61
const Math64x61_ONE = 1 * Math64x61_FRACT_PART
const Math64x61_TEN = 10 * Math64x61_FRACT_PART

##################################################################
# addy of the deployer
@storage_var
func deployer_addy() -> (addy : felt):
end

# set the addy of the delpoyer on deploy 
@constructor
func constructor{syscall_ptr : felt*,pedersen_ptr : HashBuiltin*,range_check_ptr}(deployer : felt):
    deployer_addy.write(deployer)
    return ()
end

# who is deployer
@view
func get_deployer_addy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (addy : felt):
    let (addy) = deployer_addy.read()
    return (addy)
end

##################################################################
# Trusted addy, only deployer can point contract to Trusted Addy contract
# addy of the Trusted Addy contract
@storage_var
func trusted_addy() -> (addy : felt):
end

# get the trusted contract addy
@view
func get_trusted_addy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*,range_check_ptr}() -> (addy : felt):
    let (addy) = trusted_addy.read()
    return (addy)
end

# set the trusted contract addy
@external
func set_trusted_addy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(addy : felt):
    let (caller) = get_caller_address()
    let (deployer) = deployer_addy.read()
    with_attr error_message("Only deployer can change the Trusted addy."):
        assert caller = deployer
    end
    trusted_addy.write(addy)
    return ()
end

##################################################################
# need to emit LP events so that we can do reporting / dashboard to monitor system
# dont need to emit total lp and capital since can do that with history of changes
# events keeping tracks of what happened
@event
func lp_token_change(addy : felt, lp_change : felt, capital_change : felt):
end

##################################################################
# LP contract functions
# Issue LP tokens to user
@external
func deposit_USDC_vs_lp_token{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(depo_USD : felt) -> (lp : felt):

    # Verify that the amount is positive, depo_USD is a Math64x61 type
    with_attr error_message("Amount must be positive."):
        assert_nn(depo_USD)
    end

    # Obtain the address of the account contract & czcore
    let (user) = get_caller_address()
    let (_trusted_addy) = trusted_addy.read()
    let (czcore_addy) = TrustedAddy.get_czcore_addy(_trusted_addy)

    # check for existing lp tokens and capital from czcore
    let (lp_total,capital_total,loan_total,insolvency_shortfall) = CZCore.get_cz_state(czcore_addy)
    # calc new total capital
    let new_capital_total = Math64x61_add(capital_total,depo_USD)

    # lock up
    let (settings_addy) = TrustedAddy.get_settings_addy(_trusted_addy)
    let (lockup_period) = Settings.get_lockup_period(settings_addy)
    let (block_ts) = get_block_timestamp()
    # all numbers are 64x61 type
    tempvar block_ts_64x61 = block_ts * Math64x61_ONE

    # transfer the actual USDC tokens to CZCore reserves
    let (usdc_addy) = TrustedAddy.get_usdc_addy(_trusted_addy)
    # get user USDC balance
    let (usd_user) = CZCore.erc20_balanceOf(czcore_addy, usdc_addy, user)
    let (decimals) = CZCore.erc20_decimals(czcore_addy, usdc_addy)
    # do decimal conversion so comparing like with like
    let (decimals_pow) = Math64x61_pow(Math64x61_TEN,decimals)
    let (depo_USD_mlt) = Math64x61_mul(depo_USD,decimals_pow)
    let (depo_USD_std) = Math64x61_div(depo_USD_mlt,Math64x61_ONE) 
    # Verify that the user has sufficient funds before call
    with_attr error_message("User does not have sufficient funds."):
       assert_nn_le(depo_USD_std, usd_user)
    end

    # calc new lp total and new lp issuance
    if lp_total == 0:
        let new_lp_total = depo_USD
        let new_lp_issuance = depo_USD
      
        # transfer the actual USDC tokens to CZCore reserves
        CZCore.erc20_transferFrom(czcore_addy, usdc_addy, user, czcore_addy, depo_USD_std)

        # store all new data
        CZCore.set_lp_capital_total(czcore_addy,new_lp_total,new_capital_total)
        
	# mint the lp token
	let (lp_user,lockup) = CZCore.get_lp_balance(czcore_addy,user)
        tempvar x = Math64x61_add(lp_user,new_lp_issuance)
        tempvar y = Math64x61_add(block_ts_64x61,lockup_period)
        CZCore.set_lp_balance(czcore_addy,user, x, y)

        # event
        lp_token_change.emit(addy=user,lp_change=new_lp_issuance,capital_change=depo_USD)
        return (new_lp_issuance)
    else:	
        let (new_lp_total_mlt) = Math64x61_mul(new_capital_total,lp_total)
        let (new_lp_total) = Math64x61_div(new_lp_total_mlt, capital_total)
	let new_lp_issuance = Math64x61_sub(new_lp_total, lp_total)

        # transfer the actual USDC tokens to CZCore reserves
        CZCore.erc20_transferFrom(czcore_addy, usdc_addy, user, czcore_addy, depo_USD_std)

        # store all new data
	CZCore.set_lp_capital_total(czcore_addy,new_lp_total,new_capital_total)
	
	# mint the lp token
	let (lp_user,lockup) = CZCore.get_lp_balance(czcore_addy,user)
        tempvar x = Math64x61_add(lp_user,new_lp_issuance)
        tempvar y = Math64x61_add(block_ts_64x61,lockup_period)
        CZCore.set_lp_balance(czcore_addy,user, x, y)

        # event
        lp_token_change.emit(addy=user,lp_change=new_lp_issuance,capital_change=depo_USD)
        return (new_lp_issuance)
    end
end

# redeem LP tokens from user
@external
func withdraw_USDC_vs_lp_token{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(with_LP : felt) -> (usd : felt):

    # Obtain the address of the czcore contract
    let (_trusted_addy) = trusted_addy.read()
    let (czcore_addy) = TrustedAddy.get_czcore_addy(_trusted_addy)

    # check for existing lp tokens and capital
    let (lp_total,capital_total,loan_total,insolvency_shortfall) = CZCore.get_cz_state(czcore_addy)

    # verify that the amount is positive.
    with_attr error_message("Amount must be positive and below LP total available."):
        assert_nn_le(with_LP, lp_total)
    end

    # obtain the address of the account contract and user lp balance.
    let (user) = get_caller_address()
    let (lp_user,lockup) = CZCore.get_lp_balance(czcore_addy,user)
    let (block_ts) = get_block_timestamp()
    
    # can only withdraw if not in lock up
    with_attr error_message("Cant withdraw in lock up period."):
        assert_nn(block_ts-lockup)
    end

    # verify user has sufficient LP tokens to redeem
    with_attr error_message("Insufficent lp tokens to redeem."):
        assert_nn(lp_user-with_LP)
    end
	
    # calc new lp total
    let new_lp_total = lp_total-with_LP
    
    # calc new capital total and capital to return
    let (new_capital_total, _) = unsigned_div_rem(new_lp_total * capital_total, lp_total)
    let new_capital_redeem = capital_total - new_capital_total

    # transfer the actual USDC tokens from CZCore reserves
    let (usdc_addy) = TrustedAddy.get_usdc_addy(_trusted_addy)
    # CZCore.erc20_transferFrom(czcore_addy, usdc_addy, czcore_addy, user, new_capital_redeem)

    # store all new data
    CZCore.set_lp_capital_total(czcore_addy,new_lp_total,new_capital_total)
    
    # burn lp tokens
    CZCore.set_lp_balance(czcore_addy,user, lp_user - with_LP,lockup)
    
    # event
    lp_token_change.emit(addy=user,lp_change=-with_LP,capital_change=-new_capital_redeem)
    return (new_capital_redeem)
end

# whats my LP tokens worth
@view
func lp_token_worth{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(user : felt) -> (usd : felt, lockup:felt):

    # Obtain the address of the czcore contract
    let (_trusted_addy) = trusted_addy.read()
    let (czcore_addy) = TrustedAddy.get_czcore_addy(_trusted_addy)

    # check total lp tokens and capital
    let (lp_total,capital_total,loan_total,insolvency_shortfall) = CZCore.get_cz_state(czcore_addy)

    # Obtain the user lp tokens
    let (lp_user,lockup) = CZCore.get_lp_balance(czcore_addy,user)
	
    # calc user capital to return
    if lp_user == 0:
    	return (0,0)
    else:
        let (capital_user, _) = unsigned_div_rem(lp_user * capital_total, lp_total)
	return (capital_user,lockup)
    end
end

