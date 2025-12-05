// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import './interfaces/IERC20.sol';
import './interfaces/IRewardsDistributor.sol';
import './interfaces/IVotingEscrow.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";

contract RewardsDistributor is IRewardsDistributor, Ownable {

    event CheckpointToken(
        uint time,
        uint tokens
    );

    event Claimed(
        uint tokenId,
        uint amount,
        uint claim_epoch,
        uint max_epoch
    );

    event SetDepositor(address indexed old, address indexed latest);

    uint256 public immutable WEEK;

    uint public start_time;
    mapping(uint => uint) public time_cursor_of;

    uint public last_token_time;
    uint[1000000000000000] public tokens_per_week;
    uint public token_last_balance;

    address public immutable voting_escrow;
    address public immutable token;
    address public depositor;

    uint8 public constant MAX_EPOCHS = 20;

    constructor(address _voting_escrow) {
        WEEK = BlackTimeLibrary.WEEK;
        uint _t = block.timestamp / WEEK * WEEK;
        start_time = _t;
        last_token_time = _t;
        address _token = IVotingEscrow(_voting_escrow).token();
        token = _token;
        voting_escrow = _voting_escrow;
        require(IERC20(_token).approve(_voting_escrow, type(uint).max), "approval failed");
    }

    function _checkpoint_token() internal {
        uint token_balance = IERC20(token).balanceOf(address(this));
        uint to_distribute = token_balance - token_last_balance;
        token_last_balance = token_balance;

        uint t = last_token_time;
        uint since_last = block.timestamp - t;
        last_token_time = block.timestamp;
        if(to_distribute > 0){
            uint this_week = t / WEEK * WEEK;
            uint next_week = 0;

            for (uint i = 0; i < 20; i++) {
                next_week = this_week + WEEK;
                if (block.timestamp < next_week) {
                    if (since_last == 0 && block.timestamp == t) {
                        tokens_per_week[this_week] += to_distribute;
                    } else {
                        tokens_per_week[this_week] += to_distribute * (block.timestamp - t) / since_last;
                    }
                    break;
                } else {
                    if (since_last == 0 && next_week == t) {
                        tokens_per_week[this_week] += to_distribute;
                    } else {
                        tokens_per_week[this_week] += to_distribute * (next_week - t) / since_last;
                    }
                }
                t = next_week;
                this_week = next_week;
            }
        }
        emit CheckpointToken(block.timestamp, to_distribute);
    }

    function checkpoint_token() external {
        require(msg.sender == depositor, "NOT_DEPOSITOR");
        _checkpoint_token();
    }

    function _claim(uint _tokenId, address ve, uint _last_token_time) internal returns (uint) {
        uint to_distribute = 0;

        uint max_user_epoch = IVotingEscrow(ve).user_point_epoch(_tokenId);
        uint _start_time = start_time;

        if (max_user_epoch == 0) return 0;

        uint week_cursor = time_cursor_of[_tokenId];
        if (week_cursor == 0) {
            IVotingEscrow.Point memory user_point = IVotingEscrow(ve).user_point_history(_tokenId, 1);
            week_cursor = user_point.ts / WEEK * WEEK;
        }

        if (week_cursor >= _last_token_time) return 0;
        if (week_cursor < _start_time) week_cursor = _start_time;

        uint supply;

        for (uint i = 0; i < MAX_EPOCHS; i++) {
            if (week_cursor >= _last_token_time) break;
            uint balance_of = IVotingEscrow(ve).balanceOfNFTAt(_tokenId, week_cursor + WEEK - 1);
            supply = IVotingEscrow(ve).totalSupplyAtT(week_cursor + WEEK - 1);
            supply = supply == 0 ? 1 : supply;
            to_distribute += balance_of * tokens_per_week[week_cursor] / supply;
            week_cursor += WEEK;
        }
        time_cursor_of[_tokenId] = week_cursor;

        emit Claimed(_tokenId, to_distribute, week_cursor, max_user_epoch);

        return to_distribute;
    }

    function _claimable(uint _tokenId, address ve, uint _last_token_time) internal view returns (uint) {
        uint to_distribute = 0;

        uint max_user_epoch = IVotingEscrow(ve).user_point_epoch(_tokenId);
        uint _start_time = start_time;

        if (max_user_epoch == 0) return 0;

        uint week_cursor = time_cursor_of[_tokenId];
        if (week_cursor == 0) {
            IVotingEscrow.Point memory user_point = IVotingEscrow(ve).user_point_history(_tokenId, 1);
            week_cursor = user_point.ts / WEEK * WEEK;
        }

        if (week_cursor >= _last_token_time) return 0;
        if (week_cursor < _start_time) week_cursor = _start_time;
        uint supply;

        for (uint i = 0; i < MAX_EPOCHS; i++) {
            if (week_cursor >= _last_token_time) break;
            uint balance_of = IVotingEscrow(ve).balanceOfNFTAt(_tokenId, week_cursor + WEEK - 1);
            supply = IVotingEscrow(ve).totalSupplyAtT(week_cursor + WEEK - 1);
            supply = supply == 0 ? 1 : supply;
            to_distribute += balance_of * tokens_per_week[week_cursor] / supply;
            week_cursor += WEEK;
        }

        return to_distribute;
    }

    function claimable(uint _tokenId) external view returns (uint) {
        uint _last_token_time = last_token_time / WEEK * WEEK;
        return _claimable(_tokenId, voting_escrow, _last_token_time);
    }

    function claim(uint256 _tokenId) external returns (uint256) {
        uint _last_token_time = last_token_time;
        _last_token_time = _last_token_time / WEEK * WEEK;
        uint amount = _claim(_tokenId, voting_escrow, _last_token_time);
        if (amount != 0) {
            // if locked.end then send directly
            IVotingEscrow.LockedBalance memory _locked = IVotingEscrow(voting_escrow).locked(_tokenId);
            // If lock has expired and is not permanent, transfer tokens directly
            if (_locked.end < block.timestamp && !_locked.isPermanent) {
                address _nftOwner = IVotingEscrow(voting_escrow).ownerOf(_tokenId);
                IERC20(token).transfer(_nftOwner, amount);
            } else {
                IVotingEscrow(voting_escrow).deposit_for(_tokenId, amount);
            }
            token_last_balance -= amount;
        }
        return amount;
    }

    function claim_many(uint[] memory _tokenIds) external returns (bool) {
        uint _last_token_time = last_token_time;
        _last_token_time = _last_token_time / WEEK * WEEK;
        address _voting_escrow = voting_escrow;
        uint total = 0;
        uint tokenIdsLen = _tokenIds.length;

        for (uint i = 0; i < tokenIdsLen; i++) {
            uint _tokenId = _tokenIds[i];
            require(_tokenId != 0, "INVALID_TOKEN_ID");
            uint amount = _claim(_tokenId, _voting_escrow, _last_token_time);
            if (amount != 0) {
                // if locked.end then send directly
                IVotingEscrow.LockedBalance memory _locked = IVotingEscrow(_voting_escrow).locked(_tokenId);
                if(_locked.end < block.timestamp && !_locked.isPermanent){
                    address _nftOwner = IVotingEscrow(_voting_escrow).ownerOf(_tokenId);
                    IERC20(token).transfer(_nftOwner, amount);
                } else {
                    IVotingEscrow(_voting_escrow).deposit_for(_tokenId, amount);
                }
                total += amount;
            }
        }
        if (total != 0) {
            token_last_balance -= total;
        }

        return true;
    }

    function setDepositor(address _depositor) external onlyOwner {
        emit SetDepositor(depositor, _depositor);
        depositor = _depositor;
    }

    function withdrawERC20(address _token) external onlyOwner {
        require(_token != address(0));
        uint256 _balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transfer(msg.sender, _balance);
    }
}
