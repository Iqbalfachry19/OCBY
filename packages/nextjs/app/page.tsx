"use client";
import Link from "next/link";
import Image from "next/image";
import { ConnectedAddress } from "~~/components/ConnectedAddress";
import { AddressPurpose, request, RpcErrorCode } from "sats-connect";
import { useState } from "react";
import Wallet from "sats-connect";
import { DebugContracts } from "./debug/_components/DebugContracts";
const Home = () => {
  const [amount, setAmount] = useState("");
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [address, setAddress] = useState<string | undefined>("");
  const btcToSatoshis = (btc) => {
    const [whole, fraction = ""] = btc.split(".");
    const satoshis =
      BigInt(whole) * 100000000n + BigInt(fraction.padEnd(8, "0").slice(0, 8)); // max 8 decimals
    return satoshis;
  };

  const handleSend = async (e) => {
    e.preventDefault();
    setMessage("");
    setLoading(true);

    try {
      const satoshis = btcToSatoshis(amount);
      if (satoshis < 6000n) {
        setMessage("⚠️ Minimum transfer amount is 6,000 sats (0.00006 BTC)");
        setLoading(false);
        return;
      }
      const halfSats = satoshis / 2n;
      // Step 0: Get BTC address from API
      const addressResponse = await fetch(
        "http://localhost:8000/wallet/address"
      );
      if (!addressResponse.ok) throw new Error("Failed to fetch BTC address");
      const { btcAddress } = await addressResponse.json();

      // Step 1: Send BTC transfer using the fetched address
      const response = await request("sendTransfer", {
        recipients: [
          {
            address: btcAddress, // use the API-fetched address
            amount: Number(satoshis), // your SDK might support BigInt
          },
        ],
      });

      if (response.status === "success") {
        setMessage("✅ Transaction sent successfully!");

        // Step 2: Trigger swap on Express server
        const swapResponse = await fetch("http://localhost:8000/swap/btc", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ amountSats: halfSats.toString() }),
        });

        const swapData = await swapResponse.json();

        if (swapResponse.ok) {
          setMessage(
            `✅ Transaction sent and swap executed!\nBTC TX ID: ${swapData.btcTxId}\nSTRK TX ID: ${swapData.starknetTxId}`
          );
        } else {
          setMessage(`⚠️ Swap error: ${swapData.error || "Unknown error"}`);
        }

        // Step 2: Trigger swap on Express server
        const swapResponsestrk = await fetch(
          "http://localhost:8000/swap/strk",
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ amountSats: halfSats.toString() }),
          }
        );

        const swapDatastrk = await swapResponsestrk.json();

        if (swapResponse.ok) {
          setMessage(
            `✅ Transaction sent and swap executed!\nBTC TX ID: ${swapDatastrk.btcTxId}\nSTRK TX ID: ${swapDatastrk.starknetTxId}`
          );
        } else {
          setMessage(`⚠️ Swap error: ${swapDatastrk.error || "Unknown error"}`);
        }
        const depositData = await deposit(amount); // <<< panggil deposit di sini
        setMessage(
          (prev) =>
            prev +
            `\n✅ Deposit executed!\nDeposit TX Hash: ${depositData.txHash}`
        );
      } else {
        if (response.error?.code === "USER_REJECTION") {
          setMessage("❌ Transaction rejected by user.");
        } else {
          setMessage(`⚠️ Error: ${response.error?.message || "Unknown error"}`);
        }
      }
    } catch (err) {
      setMessage(`❌ Failed: ${err.error?.message || err.message}`);
    } finally {
      setLoading(false);
    }
  };
  const handleRedeem = async (e) => {
    e.preventDefault();
    setMessage("");
    setLoading(true);

    try {
      const satoshis = btcToSatoshis(amount);
      if (satoshis < 6000n) {
        setMessage("⚠️ Minimum transfer amount is 6,000 sats (0.00006 BTC)");
        setLoading(false);
        return;
      }
      const halfSats = satoshis / 2n;

      setMessage("✅ Transaction sent successfully!");
      const response = await Wallet.request("wallet_getAccount", null);

      if (response.status === "error") {
        console.error(response.error);
        return;
      }

      console.log(response.result);

      const paymentAddressItem = response.result.addresses.find(
        (address) => address.purpose === AddressPurpose.Payment
      );

      setAddress(paymentAddressItem?.address);

      const withdrawData = await withdraw(amount);

      if (!withdrawData || !withdrawData.txHash) {
        setMessage(
          (prev) => prev + "\n⚠️ Withdraw failed or no data returned."
        );
        return;
      }

      setMessage(
        (prev) =>
          prev +
          `\n✅ Withdraw executed!\nDeposit TX Hash: ${withdrawData.txHash}`
      );

      // Step 2: Trigger swap on Express server
      const swapResponse = await fetch("http://localhost:8000/redeem/btc", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ amountSats: halfSats.toString(), address }),
      });

      const swapData = await swapResponse.json();

      if (swapResponse.ok) {
        setMessage(
          `✅ Transaction sent and swap executed!\nBTC TX ID: ${swapData.btcTxId}\nSTRK TX ID: ${swapData.starknetTxId}`
        );
      } else {
        setMessage(`⚠️ Swap error: ${swapData.error || "Unknown error"}`);
      }
    } catch (err) {
      setMessage(`❌ Failed: ${err.error?.message || err.message}`);
    } finally {
      setLoading(false);
    }
  };
  // src/api/starknetApi.ts
  async function deposit(amount: string) {
    const satoshis = btcToSatoshis(amount);
    if (satoshis < 6000n) {
      setMessage("⚠️ Minimum transfer amount is 6,000 sats (0.00006 BTC)");
      setLoading(false);
      return;
    }
    const halfSats = satoshis / 2n;
    try {
      const response = await fetch("http://localhost:8000/contract/deposit", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ amount: halfSats.toString() }),
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || "Deposit failed");
      }

      const data = await response.json();
      console.log(data);
      return data; // { message: "Deposit executed successfully!", txHash: "0x..." }
    } catch (err: any) {
      console.error("Deposit error:", err);
      throw err;
    }
  }
  async function withdraw(amount: string) {
    const satoshis = btcToSatoshis(amount);
    if (satoshis < 6000n) {
      setMessage("⚠️ Minimum transfer amount is 6,000 sats (0.00006 BTC)");
      setLoading(false);
      return;
    }
    const halfSats = satoshis / 2n;
    try {
      const response = await fetch("http://localhost:8000/contract/withdraw", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ amount: halfSats.toString() }),
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.error || "Deposit failed");
      }

      const data = await response.json();
      console.log(data);
      return data; // { message: "Deposit executed successfully!", txHash: "0x..." }
    } catch (err: any) {
      console.error("Deposit error:", err);
      throw err;
    }
  }
  const connect = async () => {
    try {
      const response = await request("wallet_connect", null);
      if (response.status === "success") {
        const paymentAddressItem = response.result.addresses.find(
          (address) => address.purpose === AddressPurpose.Payment
        );
        const ordinalsAddressItem = response.result.addresses.find(
          (address) => address.purpose === AddressPurpose.Ordinals
        );
        const stacksAddressItem = response.result.addresses.find(
          (address) => address.purpose === AddressPurpose.Stacks
        );
        setAddress(paymentAddressItem?.address);
      } else {
        if (response.error.code === RpcErrorCode.USER_REJECTION) {
          // handle user cancellation error
        } else {
          // handle error
        }
      }
    } catch (err) {
      alert(err.error.message);
    }
  };
  const disconnect = async () => {
    try {
      const response = await request("wallet_disconnect", null);
      if (response.status === "success") {
        console.log(response);
      } else {
        if (response.error.code === RpcErrorCode.USER_REJECTION) {
          // handle user cancellation error
        } else {
          // handle error
        }
      }
    } catch (err) {
      alert(err.error.message);
    }
  };
  return (
    <div className="flex flex-col items-center justify-center min-h-screen bg-gradient-to-br from-slate-900 to-slate-800 text-white">
      <header className="w-full flex items-center justify-between px-6 py-1 bg-slate-900/80 backdrop-blur-lg shadow-lg">
        <div className="flex items-center gap-3">
          <Image
            src="/logo.png"
            alt="One Click BTC Yield"
            width={150}
            height={40}
            className="rounded-md"
          />
        </div>
        <div>
          {!address ? (
            <button
              onClick={connect}
              className="px-4 py-2 rounded-lg bg-green-600 hover:bg-green-700 transition"
            >
              Connect Wallet
            </button>
          ) : (
            <button
              onClick={disconnect}
              className="px-4 py-2 rounded-lg bg-red-600 hover:bg-red-700 transition"
            >
              Disconnect
            </button>
          )}
        </div>
      </header>

      {/* MAIN CARD */}
      <div className="w-full max-w-lg bg-slate-900/70 backdrop-blur-lg rounded-2xl shadow-2xl p-8 mt-10">
        {address && (
          <p className="text-center text-sm text-slate-300 mb-6">
            Connected: <span className="font-mono">{address}</span>
          </p>
        )}

        {/* Send BTC */}
        <form
          onSubmit={handleSend}
          className="space-y-4 bg-slate-800/50 p-5 rounded-xl shadow-inner"
        >
          <label className="block text-sm font-medium">Amount (BTC)</label>
          <input
            type="number"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            required
            min="0"
            step="0.00000001"
            className="w-full p-3 rounded-lg bg-slate-900 border border-slate-700 text-white focus:outline-none focus:ring-2 focus:ring-blue-500"
            placeholder="0.001"
          />

          <button
            type="submit"
            disabled={loading}
            className="w-full py-3 rounded-lg font-semibold bg-blue-600 hover:bg-blue-700 disabled:opacity-50 transition"
          >
            {loading ? "Processing..." : "Send BTC"}
          </button>
        </form>

        {/* Redeem section */}
        <form
          onSubmit={handleRedeem}
          className="mt-6 bg-slate-800/50 p-5 rounded-xl shadow-inner"
        >
          <button
            type="submit"
            disabled={loading}
            className="w-full py-3 rounded-lg font-semibold bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 transition"
          >
            {loading ? "Processing..." : "Redeem BTC"}
          </button>
        </form>

        {/* Deposit / Withdraw buttons */}
        <div className="flex gap-4 mt-6">
          <button
            onClick={() => deposit(amount)}
            disabled={loading}
            className="flex-1 py-3 rounded-lg bg-teal-600 hover:bg-teal-700 disabled:opacity-50 transition"
          >
            {loading ? "Depositing..." : "Deposit"}
          </button>
          <button
            onClick={() => withdraw(amount)}
            disabled={loading}
            className="flex-1 py-3 rounded-lg bg-yellow-600 hover:bg-yellow-700 disabled:opacity-50 transition"
          >
            {loading ? "Withdrawing..." : "Withdraw"}
          </button>
        </div>

        {/* Status messages */}
        {message && (
          <div className="mt-6 p-4 rounded-lg bg-slate-800 border border-slate-700 text-sm whitespace-pre-wrap">
            {message}
          </div>
        )}

        {/* BTC warning */}
        <div className="mt-4 p-3 rounded-lg bg-yellow-500/20 border border-yellow-500 text-yellow-300 text-xs">
          ⚠️ Bitcoin transactions may take several minutes to confirm on-chain.
          Please wait until the transaction is included in a block before
          redeeming or withdrawing.
        </div>
      </div>

      {/* Debug panel */}
      <div className="w-full mt-8">
        <DebugContracts />
      </div>
    </div>
  );
};

export default Home;
