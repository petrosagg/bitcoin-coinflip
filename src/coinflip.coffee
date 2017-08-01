_ = require 'lodash'
bitcoin = require 'bitcoinjs-lib'

NONCE_SIZE = 16

hex = (a) -> _.padStart(a.toString(16), 2, '0')

nonce2commit = (nonce) -> bitcoin.crypto.hash160(Buffer.from(nonce, 'hex')).toString('hex')

addr2hash = (addr) -> bitcoin.address.fromBase58Check(addr).hash.toString('hex')

exports.sign = (tx, vin, keyPair, aNonce, bNonce, aAddr, bAddr) ->
	redeemPubScript = createRedeemPubScript(nonce2commit(aNonce), nonce2commit(bNonce), aAddr, bAddr)

	hashType = bitcoin.Transaction.SIGHASH_ALL

	sighash = tx.hashForSignature(vin, redeemPubScript, hashType)

	p2shSigScriptSource = [
		keyPair.sign(sighash).toScriptSignature(hashType).toString('hex')
		keyPair.getPublicKeyBuffer().toString('hex')
		bNonce
		aNonce
		redeemPubScript.toString('hex')
	].join(' ')

	p2shSigScript = bitcoin.script.fromASM(p2shSigScriptSource)

	tx.setInputScript(vin, p2shSigScript)

exports.createRedeemPubScript = createRedeemPubScript = (aCommit, bCommit, aAddr, bAddr) ->
	# This ensure both parties end up calculating the same script
	if bCommit < aCommit
		[ aCommit, bCommit ] = [ bCommit, aCommit ]
		[ aAddr, bAddr ] = [ bAddr, aAddr ]
	
	# The comments bellow follow the stack contents as the Bitcoin Script executes

	# redeemPub arguments: [ sig, pubKey, bNonce, aNonce ]
	redeemPubScriptSource = [
		# Duplicate the two nonces that should be at the top of the stack. This
		# is because calculating their HASH160 consumes them and we need them
		# again later
		'OP_2DUP' # stack = [ sig, pubKey, bNonce, aNonce, bNonce, aNonce ]

		# Check Alice's nonce is the one she commited too
		'OP_HASH160', aCommit, 'OP_EQUALVERIFY' # stack = [ sig, pubKey, bNonce, aNonce, bNonce ]

		# Check Bob's commit
		'OP_HASH160', bCommit, 'OP_EQUALVERIFY' # stack = [ sig, pubKey, bNonce, aNonce ]

		# Compute Alice's value
		'OP_SIZE', 'OP_NIP', hex(NONCE_SIZE), 'OP_NUMEQUAL' # stack = [ sig, pubKey, bNonce, aValue ]

		# Bring Bob's nonce at the top of the stack
		'OP_SWAP' # stack = [ sig, pubKey, aValue, bNonce ]

		# Compute Bob's value
		'OP_SIZE', 'OP_NIP', hex(NONCE_SIZE), 'OP_NUMEQUAL' # stack = [ sig, pubKey, aValue, bValue]

		# Alice wins if Bob had the same value
		'OP_NUMEQUAL' # [ sig, pubKey, aliceWon ]

		# Push spender's public key hash on the stack
		'OP_IF' # if aliceWon
			addr2hash(aAddr) # stack = [ sig, pubKey, aPubKeyHash ]
		'OP_ELSE'
			addr2hash(bAddr) # stack = [ sig, pubKey, bPubKeyHash ]
		'OP_ENDIF'

		# Copy spender's pubkey at the top of the stack
		'OP_OVER' # stack = [ sig, pubKey, winnerPubKeyHash, pubKey ]

		# Compute its hash
		'OP_HASH160' # stack = [ sig, pubKey, winnerPubKeyHash, pubKeyHash ]

		# Make sure it's equal to the winner's hash
		'OP_EQUALVERIFY' # stack = [ sig, pubKey ]

		# Verify signature
		'OP_CHECKSIG' # stack = [ ]
	].join(' ')

	return bitcoin.script.fromASM(redeemPubScriptSource)

exports.createP2SHAddr = (aCommit, bCommit, aAddr, bAddr, network) ->
	redeemScript = exports.createRedeemPubScript(aCommit, bCommit, aAddr, bAddr)

	p2shScriptPub = bitcoin.script.scriptHash.output.encode(bitcoin.crypto.hash160(redeemScript))

	return bitcoin.address.fromOutputScript(p2shScriptPub, network)
