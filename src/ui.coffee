crypto = require 'crypto'

_ = require 'lodash'
Big = require 'big.js'
low = require 'lowdb'
colors = require 'colors/safe'
inquirer = require 'inquirer'
bitcoin = require 'bitcoinjs-lib'
{ blockexplorer } = require('blockchain.info')

NONCE_SIZE = 16

state = low('state.json')

state.defaults({
	privateKey: null
	games: []
}).write()

utxos = []
balance = 0
keyPair = null
address = null

initKeyPair = ->
	privateKey = state.get('privateKey').value()
	if privateKey is null
		console.log('Creating new wallet..')
		keyPair = bitcoin.ECPair.makeRandom()
		state.set('privateKey', keyPair.toWIF()).write()
	else
		keyPair = bitcoin.ECPair.fromWIF(privateKey)
		console.log('Loaded wallet from disk')

	address = keyPair.getAddress()

createGame = ->
	game =
		opponent:
			name: 'Bob'
			address: null
			commit: null
			amount: 0
		state: 'new'
		value: 0
		commit: null
		nonce: null
		amount: 0

	opponentBalance = 0

	questions = [
		{
			name: 'opponent.name'
			message: 'Who are you playing with?'
			default: game.opponent.name
		},
		{
			name: 'amount'
			message: 'How much will you bet? (BTC)'
			filter: Big
			validate: (btc) ->
				sha = Number(btc.mul(1e8))
				if sha <= 0
					return 'The amount should be greater than zero'
				if sha > balance
					return "You don't have enough funds for this bet"

				game.amount = sha
				return true
		},
		{
			type: 'list'
			name: 'value'
			message: 'Heads or Tails?'
			choices: _.shuffle([ 'Heads', 'Tails' ])
			filter: (side) ->
				value = if side is 'Heads' then 0 else 1

				buf = Buffer.allocUnsafe(NONCE_SIZE + value)
				crypto.randomFillSync(buf)

				commit = bitcoin.crypto.hash160(buf).toString('hex')

				game.commit = commit
				game.nonce = buf.toString('hex')
				game.value = value

				return value
		},
		{
			name: 'opponent.address'
			message: (answers) ->
				console.log('Your info:')
				console.log('Address:', address)
				console.log('Commitment:', game.commit)
				return "What is #{answers.opponent.name}'s bitcoin address?"
			validate: (addr) ->
				try
					bitcoin.address.fromBase58Check(addr)
				catch
					return 'Invalid bitcoin address'

				blockexplorer.getUnspentOutputs(addr)
				.get('unspent_outputs')
				.then (utxos) ->
					for {value} in utxos
						opponentBalance += value

					return true
		},
		{
			name: 'opponent.amount'
			message: ({opponent}) -> "How much will #{opponent.name} bet? (BTC)"
			default: (ans) -> ans.amount
			filter: Big
			validate: (btc, ans) ->
				sha = Number(btc.mul(1e8))
				if sha <= 0
					return 'The amount should be greater than zero'
				if sha > opponentBalance
					return "#{ans.opponent.name} doen't have enough funds for this bet"

				game.opponent.amount = sha
				return true
		},
		{
			name: 'opponent.commit'
			message: ({opponent}) ->"What is #{opponent.name}'s commitment?"
			validate: (commit) ->
				buf = Buffer.from(commit, 'hex')
				if buf.length isnt 20
					return 'Invalid commitment'
				return true
		},
	]
	inquirer.prompt(questions)
	.then (answers) ->
		game.opponent.name = answers.opponent.name
		game.opponent.commit = answers.opponent.commit
		game.opponent.address = answers.opponent.address
		console.log('Saving game state')
		state.get('games').push(game).write()
		return game

checkBalance = ->
	console.log('Checking available UTXOs..')

	blockexplorer.getUnspentOutputs(address, confirmations: 1)
	.get('unspent_outputs')
	.then (result) ->
		utxos = result
		for {value} in utxos
			balance += value
	.catch (e) ->
		if e is 'No free outputs to spend'
			console.log(colors.red("You don't have any funds to play with. Send some funds and try again later"))
		else
			console.log('Unexpected error:', e)
		throw e

chooseGame = ->
	games = state.get('games').value()

	if games.length is 0
		console.log('> You have no ongoing games')
	else
		console.log(colors.green('> You have', games.length, 'ongoing games'))

	inquirer.prompt([
		{
			type: 'confirm'
			name: 'newGame'
			message: 'Would you like to start a new game?'
			default: true
		}
	]).then ({newGame}) ->
		if newGame
			return createGame()
		else if games.length > 0
			gameChoices = _.keyBy(games, (g) -> "#{g.opponent.name} - #{Big(g.amount).div(1e8)}BTC")

			questions = [
				{
					type: 'list'
					name: 'game'
					message: 'Choose game to resume'
					choices: Object.keys(gameChoices)
					filter: (choice) -> gameChoices[choice]
				}
			]
			return inquirer.prompt(questions).then((answer) -> answer.game)
		else
			throw new Error()

finalizeGame = (game) ->
	p2shAddress = createCoinflipScript(address, game.opponent.address, game.commit, game.opponent.commit)

	# deterministically decide who will generate the tx and who will wait
	shouldCreateTx = game.commit < game.opponent.commit

	if shouldCreateTx
		tx = new bitcoin.TransactionBuilder()
		tx.addInput(utxos[0], 0)
		tx.addOutput(p2shAddress, game.amount + game.opponent.amount)
		# XXX: add change
		txb.sign(0, keyPair)
	else # wait for signed tx
		inquirer.prompt(
			name: 'input'
			message: "Enter #{game.opponent.name}'s signed input"
		)
		.then ({input}) ->
			console.log(input)
		
main = ->
	console.log(colors.bold('- Welcome to bitcoin coinflip!'))
	initKeyPair()

	checkBalance()
	.then(chooseGame)
	.catch ->
		console.log('Goodbye')
		process.exit()

main()
